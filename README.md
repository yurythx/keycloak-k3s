# 🏛️ keycloak-k3s — Stack de Autenticação Governamental (Prefeitura de Rondonópolis-MT)

Stack de autenticação e cofre de senhas, self-hosted, implantada em **K3s**
via **GitOps** com **GitHub Actions** e um **Self-Hosted Runner** — sem
nunca expor SSH ou a API do Kubernetes para a internet.

| Componente | Função | Réplicas | Domínio público | Porta na VM |
|---|---|---|---|---|
| **Keycloak 26 (Quarkus)** | Identity Provider (SSO, OIDC/SAML) para os sistemas da prefeitura | 2 (alta disponibilidade) | `sso.rondonopolis.mt.gov.br` | `18443` |
| **PostgreSQL 16-alpine** | Banco de dados persistente do Keycloak | 1 | (interno, sem acesso externo) | — |
| **Vaultwarden** | Cofre de senhas (compatível com Bitwarden) para as equipes de TI/administração | 1 | `cofre.rondonopolis.mt.gov.br` | `8081` |
| **Nginx (fora do K3s)** | Servidor de borda **já existente** na rede da prefeitura — termina o HTTPS público | — | recebe os 2 domínios acima | 80/443 |

Este repositório já está **100% pronto para ser aplicado na VM assim que
ela existir** — os domínios reais, o clustering do Keycloak, o backup
automático e a segmentação de rede já estão todos configurados nos
manifestos. O que falta é só a parte física (seção 4).

---

## 1. Arquitetura adotada

```
                         Internet
                            │
                            │  Portas 80/443 (o Nginx da borda já cuida disso)
                            ▼
                  ┌─────────────────────┐
                  │  Nginx (borda, já    │  ← Servidor JÁ EXISTENTE na rede da
                  │  existe na rede)     │    prefeitura (aaPanel/BT Panel).
                  │  TERMINA o TLS       │    Vhosts JÁ CONFIGURADOS, SEM
                  └──────────┬──────────┘    NENHUMA alteração necessária.
                             │
              ┌──────────────┴─────────────┐
              │  proxy_pass para            │  proxy_pass para
              │  192.168.0.225:18443        │  192.168.0.225:8081
              ▼  (mesma porta de sempre)    ▼  (mesma porta de sempre)
   ┌─────────────────────┐      ┌─────────────────────┐
   │ Service LoadBalancer │      │ Service LoadBalancer │
   │ keycloak-external     │      │ vaultwarden-external │
   │ (porta 18443, K3s)    │      │ (porta 8081, K3s)    │
   └──────────┬──────────┘      └──────────┬──────────┘
              │ 2 réplicas                  │ 1 réplica
   ┌──────────▼──────────┐      ┌──────────▼──────────┐
   │  Pod keycloak-1       │      │  Pod vaultwarden     │
   │  Pod keycloak-2       │      │  (PVC dedicado 5Gi)  │
   │  (cache ispn/DNS_PING)│      └──────────────────────┘
   └──────────┬──────────┘
              │  🔒 NetworkPolicy: só o Keycloak acessa a porta 5432
   ┌──────────▼──────────┐
   │  Service: postgres    │
   └──────────┬──────────┘
   ┌──────────▼──────────┐         ┌────────────────────────┐
   │  Pod postgres          │◄─────┤ CronJob: backup diário  │
   │  (PVC dedicado 10Gi)   │      │ (pg_dump 03h, PVC 5Gi,  │
   └──────────────────────┘       │  retenção de 7 dias)    │
                                   └────────────────────────┘
```

**Por que cada serviço é exposto na MESMA porta que já usava antes (18443
e 8081), em vez de um Ingress único na porta 80:** esta VM já hospedava um
Keycloak e um Vaultwarden bare-metal (ambiente de teste/POC, hoje
desligados) nessas exatas portas, e o Nginx da borda já tem os vhosts
configurados apontando para elas. Em vez de migrar para um esquema
diferente (Ingress+Traefik na porta 80, roteando por domínio) — o que
exigiria editar a configuração do Nginx, gerenciado por outra
equipe/processo — o K3s foi configurado para **ocupar exatamente as
mesmas portas de antes**, via `Service` do tipo `LoadBalancer` (usando o
ServiceLB embutido do K3s, sem precisar instalar nada extra). Resultado:
**zero alterações necessárias no Nginx**. Detalhes completos em
`nginx-edge/README.md`.

**Namespace único:** todos os recursos vivem dentro de `authentication`,
isolados do resto do cluster.

**Segurança de rede:** o Self-Hosted Runner do GitHub Actions roda DENTRO
da VM e abre uma conexão de **saída** para buscar trabalho na GitHub —
nenhuma porta de entrada (SSH, API do Kubernetes) precisa ficar exposta.
A VM só precisa ser alcançável pelo Nginx da borda, nas portas 18443 e
8081 — nunca diretamente da internet.

**Persistência:** PostgreSQL, Vaultwarden e os backups gravam em
**PersistentVolumeClaims** usando a StorageClass `local-path` (já embutida
no K3s), que grava diretamente no disco físico da VM em
`/var/lib/rancher/k3s/storage/`. Um reinício de Pod, do K3s ou até da VM
**não apaga os dados**.

**Segmentação de rede:** uma `NetworkPolicy` restringe o PostgreSQL para só
aceitar conexões vindas dos Pods do Keycloak — nenhum outro workload do
namespace consegue alcançar o banco (ver aviso sobre CNI/enforcement em
`k3s-cluster/network-policy.yaml`).

**Backup:** um `CronJob` roda `pg_dump` todo dia às 03:00 (horário de
Rondonópolis-MT), compacta o resultado e mantém os últimos 7 dias
automaticamente, em um disco separado do disco de dados (ver limitação
sobre backup off-site em `k3s-cluster/postgres-backup-cronjob.yaml`).

---

## 2. Consumo de memória (por que cabe em 8GB de RAM)

| Processo | RAM (request) | RAM (limit) |
|---|---|---|
| Sistema Operacional + K3s (control-plane + kubelet) | ~800Mi | — |
| PostgreSQL | 256Mi | 512Mi |
| Keycloak (× 2 réplicas) | 600Mi cada (1200Mi total) | 1024Mi cada (2048Mi total) |
| Vaultwarden | 64Mi | 128Mi |
| Backup CronJob (só durante a execução diária, ~1 min/dia) | 64Mi | 256Mi |
| Traefik (já incluso no K3s, usado só internamente) | ~50Mi | — |
| **Total aproximado no pior caso (limits)** | | **~3,5 GiB** |

Isso deixa **mais de 4GB de RAM livres** na VM de 8GB para picos de tráfego,
cache de disco do sistema operacional e crescimento futuro — uma margem de
segurança confortável para não sofrer com OOM (Out of Memory) em produção.
Como o HTTPS é terminado no Nginx da borda (fora desta VM), não rodamos
cert-manager dentro do cluster — uma peça a menos disputando RAM. A VM
também precisa dividir espaço com apenas **2 vCPUs**, então evite rodar
cargas de teste pesadas simultâneas nos primeiros deploys.

> 💡 Todos os limites de CPU/RAM estão declarados nos próprios manifestos
> (`resources.requests` / `resources.limits`), comentados linha a linha —
> ajuste-os em `k3s-cluster/keycloak.yaml`, `postgres-db.yaml` e
> `vaultwarden.yaml` conforme a carga real observada.

---

## 3. Estrutura do repositório

```
keycloak-k3s/
├── .github/
│   └── workflows/
│       └── deploy.yml                   # Pipeline GitOps (self-hosted runner, 12 passos)
├── scripts/
│   └── bootstrap-vm.sh                  # Script único: K3s + kubectl + runner
├── nginx-edge/                          # Cópia fiel do que já está no Nginx (referência, não aplicado)
│   ├── README.md
│   ├── sso.rondonopolis.mt.gov.br.conf
│   └── cofre.rondonopolis.mt.gov.br.conf
├── k3s-cluster/
│   ├── namespaces.yaml                  # Namespace "authentication"
│   ├── secrets.yaml                     # Credenciais (Postgres, Keycloak, Vaultwarden)
│   ├── postgres-db.yaml                 # PVC + Deployment + Service do PostgreSQL
│   ├── keycloak.yaml                    # Service headless + Deployment + Services (interno + porta 18443)
│   ├── vaultwarden.yaml                 # PVC + Deployment + Services (interno + porta 8081)
│   ├── network-policy.yaml              # Restringe acesso ao Postgres só ao Keycloak
│   └── postgres-backup-cronjob.yaml     # PVC + CronJob de backup diário do banco
└── README.md                            # Este arquivo
```

---

## 4. Passo a passo de implantação na VM

### 4.1. Pré-requisitos

- VM Bare Metal/Proxmox com **Linux** (Ubuntu Server 22.04/24.04
  recomendado), **8GB de RAM**, acesso root/sudo.
- Conectividade de rede entre esta VM e o servidor **Nginx da borda**
  (mesma VLAN/sub-rede) — a VM só precisa aceitar conexões do Nginx nas
  portas 18443 e 8081.
- Os domínios `sso.rondonopolis.mt.gov.br` e `cofre.rondonopolis.mt.gov.br`
  já existiam em produção antes (Keycloak/Vaultwarden bare-metal) — o DNS
  já deve estar correto, apontando para o IP público do Nginx da borda.

### 4.2. Opção A (recomendada): script único de bootstrap automatizado

Em vez de digitar os comandos das seções 4.3 a 4.4 um por um, o script
[`scripts/bootstrap-vm.sh`](scripts/bootstrap-vm.sh) faz tudo de uma vez:
instala o K3s, configura o `kubectl` para o seu usuário e — se você
fornecer um token do GitHub — registra e inicia o Self-Hosted Runner. É
**idempotente**: rodar de novo depois não quebra nada (cada etapa verifica
se já foi feita antes de agir), então também serve para "consertar" uma VM
que ficou pela metade.

```bash
# Dentro da VM, clone o repositório (ou copie só este script via scp):
git clone https://github.com/yurythx/keycloak-k3s.git
cd keycloak-k3s
chmod +x scripts/bootstrap-vm.sh

# Opção sem registro automático do runner (registra na mão depois, seção 4.5):
sudo ./scripts/bootstrap-vm.sh

# Opção com registro automático do runner — gere antes um Personal Access
# Token em GitHub: Settings → Developer settings → Personal access tokens →
# Fine-grained → permissão "Administration: Read and write" NO REPOSITÓRIO
# keycloak-k3s (não precisa de acesso a outros repositórios):
sudo GH_PAT="ghp_xxx_seu_token" ./scripts/bootstrap-vm.sh
```

O script imprime, ao final, exatamente o que ainda falta fazer fora dele
(editar segredos) — pule direto para a seção 4.6.

> O token (`GH_PAT`) só é usado em memória, na hora de chamar a API do
> GitHub para pegar um token de registro temporário (válido ~1h) — nunca é
> salvo em disco pelo script. Prefira um token com validade curta (ex.: 7
> dias) e revogue-o depois de usar, se quiser ser ainda mais conservador.

Se preferir entender/rodar cada comando manualmente (ou se algo no script
falhar e você precisar diagnosticar um passo específico), siga a **Opção B**
abaixo — é exatamente o que o script automatiza por baixo dos panos.

### 4.3. Opção B: instalar o K3s manualmente

Conecte-se na VM (localmente ou via um acesso já existente) e rode:

```bash
# Instala o K3s como um único binário, já com Traefik e o
# local-path-provisioner (storage) inclusos por padrão.
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644
  # ↑ Deixa o arquivo de credenciais do cluster (kubeconfig) legível pelo
  #   usuário comum que vai rodar o Self-Hosted Runner (evita ter que
  #   rodar o runner como root só para ler o kubeconfig).

# Confirma que o cluster subiu:
sudo k3s kubectl get nodes
# ↑ Deve mostrar 1 nó em status "Ready".
```

> ℹ️ O instalador do K3s já vem com o **ServiceLB** embutido (usado para
> expor o Keycloak/Vaultwarden nas portas 18443/8081 — ver seção 1) e o
> **Local Path Provisioner** (StorageClass `local-path`) habilitados por
> padrão — não é preciso instalar nada extra para este projeto funcionar.

> ⚠️ **Sobre a NetworkPolicy (`network-policy.yaml`):** o K3s usa Flannel
> como CNI padrão, que **não enforça** NetworkPolicies (o recurso é
> aceito pelo cluster, mas não bloqueia tráfego de verdade). Isso não
> impede o deploy — é só uma camada de segurança que fica "adormecida"
> até você, opcionalmente, migrar para um CNI com suporte a enforcement
> (ex.: Calico). Veja o comentário completo dentro do próprio arquivo.

### 4.4. Configurar o `kubectl` para o usuário do Runner

```bash
# Cria a pasta padrão de configuração do kubectl para o seu usuário.
mkdir -p ~/.kube

# Copia o kubeconfig gerado pelo K3s (que só o root consegue ler por
# padrão) para dentro da pasta do usuário comum.
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config

# Garante que o dono do arquivo seja o seu usuário (não root).
sudo chown $(id -u):$(id -g) ~/.kube/config

# Testa o acesso:
kubectl get nodes
```

### 4.5. Registrar o Self-Hosted Runner do GitHub Actions

> Pule esta seção se você já rodou o script da seção 4.2 com `GH_PAT`
> definido — o runner já está registrado e ativo.

No GitHub: **Settings → Actions → Runners → New self-hosted runner**
(no repositório `keycloak-k3s`), selecione **Linux/x64**, e copie os
comandos exibidos (eles incluem um token temporário exclusivo, por isso não
reproduzimos o token aqui — sempre pegue o gerado na hora pela interface).
O padrão é parecido com:

```bash
# Cria uma pasta dedicada para o runner e entra nela.
mkdir actions-runner && cd actions-runner

# Baixa o pacote do runner (a versão exata vem na tela do GitHub).
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.com/actions/runner/releases/download/vX.X.X/actions-runner-linux-x64-X.X.X.tar.gz

# Extrai o pacote.
tar xzf ./actions-runner-linux-x64.tar.gz

# Configura o runner, associando-o ao repositório (token fornecido pela
# interface do GitHub, válido por tempo limitado).
./config.sh --url https://github.com/yurythx/keycloak-k3s \
  --token SEU_TOKEN_TEMPORARIO

# Instala o runner como um serviço do systemd, para ele iniciar sozinho
# junto com a VM e reiniciar automaticamente se cair.
sudo ./svc.sh install
sudo ./svc.sh start

# Confirma que o serviço está ativo:
sudo ./svc.sh status
```

> 🔒 **Segurança:** o runner se conecta à GitHub por conexão de SAÍDA
> (outbound HTTPS) para buscar trabalho — não é necessário abrir NENHUMA
> porta de entrada no firewall para o runner funcionar. Rode-o com um
> usuário Linux SEM privilégios de root (o instalador já orienta isso).

### 4.6. Ajustes finais de conteúdo (antes do primeiro deploy)

Os domínios, IPs (VM `192.168.0.225`, Nginx da borda `192.168.0.218`) e as
portas legadas (`18443`/`8081`) já estão preenchidos em `keycloak.yaml` e
`vaultwarden.yaml` — nada a fazer aí. O que ainda precisa de atenção:

1. **Troque todas as senhas fictícias** em `k3s-cluster/secrets.yaml` (veja
   o passo a passo detalhado dentro do próprio arquivo — inclui como gerar
   senhas fortes com `openssl rand -base64 32`). Considere usar o mesmo
   usuário administrador (`kc_admin`) e usuário de banco (`keycloak_user`)
   já usados no Keycloak que roda hoje fora do K3s, para manter consistência
   — só as SENHAS precisam ser reais/fortes, os nomes de usuário já batem.
2. **Nginx da borda: nada a fazer.** Os vhosts de `sso.` e `cofre.` já
   apontam para `192.168.0.225:18443` e `192.168.0.225:8081` — exatamente
   as portas que o K3s passa a ocupar. Ver `nginx-edge/README.md` para o
   detalhamento completo dessa decisão.
3. A integração com o Active Directory (`rondonopolis.local`) **foi
   deliberadamente deixada de fora desta migração** — ver nota abaixo.

> ℹ️ **Sobre a integração com Active Directory (decisão tomada):** o
> Keycloak que já roda hoje fora do K3s tem variáveis `AD_DOMAIN`,
> `AD_DC_HOSTNAME` e `AD_DC_IP` no seu `.env`, indicando federação com o
> AD (`rondonopolis.local`, `dc01.rondonopolis.local`). Essa configuração
> normalmente envolve um provider LDAP montado via Admin Console/REST API
> (com credenciais de bind que não vêm em variável de ambiente), então
> optamos por **não tentar recriar isso às cegas neste repositório**. A
> stack sobe com gestão de usuários local (banco Postgres) e, depois que o
> Keycloak novo estiver no ar, a federação com o AD é configurada
> manualmente pelo Admin Console — mesmo processo de sempre, só que
> apontando para este Keycloak em vez do que roda fora do K3s hoje.
> Caminho: **Realm → User federation → Add provider → ldap**, usando os
> mesmos dados de conexão (`AD_DC_HOSTNAME`/`AD_DC_IP`, porta 389/636,
> Base DN, etc.) e a credencial de bind que já está em uso no ambiente
> atual.

### 4.7. Disparar o primeiro deploy

```bash
git add .
git commit -m "Ajusta segredos para producao"
git push origin main
```

Acompanhe a execução em **Actions** no GitHub — o job `aplicar-manifestos`
vai rodar no seu runner self-hosted e aplicar os manifestos em ordem lógica:
Namespace → Secrets → PostgreSQL → NetworkPolicy → Backup CronJob →
Keycloak → Vaultwarden.

### 4.8. Validar a implantação

```bash
kubectl get pods -n authentication -o wide
kubectl get svc -n authentication -o wide
# ↑ Confira que "keycloak-external" mostra a porta 18443 e
#   "vaultwarden-external" mostra a porta 8081.

# Direto da VM, teste as portas que o Nginx usa:
curl -I http://localhost:18443/
curl -I http://localhost:8081/
```

Como o Nginx da borda já está configurado, acessar
`https://sso.rondonopolis.mt.gov.br` (deve mostrar a tela do Keycloak) e
`https://cofre.rondonopolis.mt.gov.br` (deve mostrar a tela do Vaultwarden)
já deve funcionar assim que os Pods ficarem saudáveis — sem nenhum passo
extra de configuração de borda.

---

## 5. Operações do dia a dia

| Tarefa | Comando |
|---|---|
| Ver logs do Keycloak | `kubectl logs -n authentication -l app=keycloak -f` |
| Ver logs do Postgres | `kubectl logs -n authentication deploy/postgres -f` |
| Reiniciar o Keycloak (após trocar segredo) | `kubectl rollout restart deployment/keycloak -n authentication` |
| Ver backups disponíveis | `kubectl run -n authentication ls-backups --rm -it --image=busybox --restart=Never --overrides='{"spec":{"containers":[{"name":"ls-backups","image":"busybox","command":["ls","-lh","/backups"],"volumeMounts":[{"name":"b","mountPath":"/backups"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"postgres-backup-pvc"}}]}}'` |
| Forçar um backup fora do horário agendado | `kubectl create job -n authentication backup-manual --from=cronjob/postgres-backup` |
| Ver uso de RAM/CPU real dos Pods | `kubectl top pods -n authentication` |
| Testar as portas legadas sem depender do Nginx | `curl -I http://IP_DA_VM:18443/` e `curl -I http://IP_DA_VM:8081/` |
| Forçar reaplicação dos manifestos | Aba **Actions** → workflow **Deploy Auth Stack para o K3s** → **Run workflow** |

---

## 6. Próximos passos recomendados (fora do escopo inicial)

- **Federação com o Active Directory (`rondonopolis.local`)**: decisão
  tomada de configurar manualmente pelo Admin Console depois do deploy,
  em vez de automatizar às cegas (ver nota completa na seção 4.6) — é o
  item de maior impacto antes de esta stack poder substituir o Keycloak
  atual em produção, já que sem ela os usuários da prefeitura não
  logariam com a conta do domínio.
- **Sealed Secrets / SOPS**: para versionar segredos criptografados no Git
  em vez de texto plano (ver aviso detalhado em `secrets.yaml`).
- **Backup off-site**: o CronJob já grava backups diários no disco da VM,
  mas uma cópia adicional para fora da VM (outro datacenter/nuvem) é
  necessária para proteger contra perda física do servidor — ver
  limitação detalhada em `postgres-backup-cronjob.yaml`.
- **MFA obrigatório** no realm do Keycloak para todos os administradores.
- **CNI com enforcement de NetworkPolicy** (ex.: Calico), caso a
  segmentação de rede precise ser efetivamente bloqueante e não apenas
  declarativa — ver aviso em `network-policy.yaml`.
- **Monitorar a validade do certificado** gerenciado pelo Nginx da borda
  (fora do escopo deste repositório, mas crítico — um certificado vencido
  ali derruba o HTTPS de toda a stack).

---

**Dúvidas ou problemas?** Cada arquivo `.yaml`/`.sh`/`.conf` deste
repositório tem comentários explicando linha a linha o que cada parâmetro
faz — comece por lá antes de alterar qualquer valor.
