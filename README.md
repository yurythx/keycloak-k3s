# 🏛️ keycloak-k3s — Stack de Autenticação Governamental (Prefeitura de Rondonópolis-MT)

Stack de autenticação e cofre de senhas, self-hosted, implantada em **K3s**
via **GitOps** com **GitHub Actions** e um **Self-Hosted Runner** — sem
nunca expor SSH ou a API do Kubernetes para a internet.

| Componente | Função | Réplicas | Domínio público |
|---|---|---|---|
| **Keycloak 26 (Quarkus)** | Identity Provider (SSO, OIDC/SAML) para os sistemas da prefeitura | 2 (alta disponibilidade) | `sso.rondonopolis.mt.gov.br` |
| **PostgreSQL 16-alpine** | Banco de dados persistente do Keycloak | 1 | (interno, sem acesso externo) |
| **Vaultwarden** | Cofre de senhas (compatível com Bitwarden) para as equipes de TI/administração | 1 | `cofre.rondonopolis.mt.gov.br` |
| **Traefik** | Ingress Controller (já incluso no K3s) — expõe os domínios públicos | — | — |
| **cert-manager** | Emite/renova certificados HTTPS válidos automaticamente (Let's Encrypt) | — | — |

Este repositório já está **100% pronto para ser aplicado na VM assim que
ela existir** — os domínios reais, o RBAC de clustering, o backup
automático, a segmentação de rede e o HTTPS válido já estão todos
configurados nos manifestos. O que falta é só a parte física (seção 4).

---

## 1. Arquitetura adotada

```
                         Internet
                            │
                            │  Portas 80/443 (únicas abertas no firewall)
                            ▼
                  ┌───────────────────┐
                  │   Traefik (K3s)   │  ← Ingress Controller nativo do K3s
                  └─────────┬─────────┘
                            │  roteamento por domínio (Host header)
                            │  TLS emitido pelo cert-manager (Let's Encrypt)
              ┌─────────────┴─────────────┐
              ▼                           ▼
 sso.rondonopolis.mt.gov.br    cofre.rondonopolis.mt.gov.br
              │                           │
   ┌──────────▼──────────┐     ┌──────────▼──────────┐
   │  Service: keycloak   │     │ Service: vaultwarden │
   └──────────┬──────────┘     └──────────┬──────────┘
              │ 2 réplicas                 │ 1 réplica
   ┌──────────▼──────────┐     ┌──────────▼──────────┐
   │  Pod keycloak-1      │     │  Pod vaultwarden     │
   │  Pod keycloak-2      │     │  (PVC dedicado 5Gi)  │
   │  (cache HA/KUBE_PING)│     └──────────────────────┘
   └──────────┬──────────┘
              │  🔒 NetworkPolicy: só o Keycloak acessa a porta 5432
   ┌──────────▼──────────┐
   │  Service: postgres   │
   └──────────┬──────────┘
   ┌──────────▼──────────┐        ┌────────────────────────┐
   │  Pod postgres         │◄─────┤ CronJob: backup diário  │
   │  (PVC dedicado 10Gi)  │      │ (pg_dump 03h, PVC 5Gi,  │
   └──────────────────────┘      │  retenção de 7 dias)    │
                                  └────────────────────────┘
```

**Namespace único:** todos os recursos vivem dentro de `authentication`,
isolados do resto do cluster.

**Segurança de rede:** o Self-Hosted Runner do GitHub Actions roda DENTRO
da VM e abre uma conexão de **saída** para buscar trabalho na GitHub —
**nenhuma porta de entrada** (SSH, API do Kubernetes) precisa ficar exposta
publicamente. Só as portas **80 e 443** (tráfego web do Traefik) precisam
estar abertas no firewall/roteador.

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

**HTTPS válido:** o `cert-manager` (instalado uma única vez, manualmente —
seção 4.2) emite e renova sozinho os certificados Let's Encrypt para os
dois domínios, sem certificado autoassinado nem alerta no navegador.

---

## 2. Consumo de memória (por que cabe em 8GB de RAM)

| Processo | RAM (request) | RAM (limit) |
|---|---|---|
| Sistema Operacional + K3s (control-plane + kubelet) | ~800Mi | — |
| PostgreSQL | 256Mi | 512Mi |
| Keycloak (× 2 réplicas) | 600Mi cada (1200Mi total) | 1024Mi cada (2048Mi total) |
| Vaultwarden | 64Mi | 128Mi |
| Backup CronJob (só durante a execução diária, ~1 min/dia) | 64Mi | 256Mi |
| Traefik + cert-manager (já incluso/instalado no K3s) | ~150Mi | — |
| **Total aproximado no pior caso (limits)** | | **~3,7 GiB** |

Isso deixa **mais de 4GB de RAM livres** na VM de 8GB para picos de tráfego,
cache de disco do sistema operacional e crescimento futuro — uma margem de
segurança confortável para não sofrer com OOM (Out of Memory) em produção.

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
│       └── deploy.yml                   # Pipeline GitOps (self-hosted runner, 14 passos)
├── k3s-cluster/
│   ├── namespaces.yaml                  # Namespace "authentication"
│   ├── secrets.yaml                     # Credenciais (Postgres, Keycloak, Vaultwarden)
│   ├── postgres-db.yaml                 # PVC + Deployment + Service do PostgreSQL
│   ├── keycloak.yaml                    # RBAC + Deployment (2 réplicas) + Service
│   ├── vaultwarden.yaml                 # PVC + Deployment + Service do Vaultwarden
│   ├── network-policy.yaml              # Restringe acesso ao Postgres só ao Keycloak
│   ├── postgres-backup-cronjob.yaml     # PVC + CronJob de backup diário do banco
│   ├── cert-manager-issuer.yaml         # ClusterIssuer Let's Encrypt (HTTPS válido)
│   └── ingress.yaml                     # Roteamento Traefik (domínios públicos + TLS)
└── README.md                            # Este arquivo
```

---

## 4. Passo a passo de implantação na VM

### 4.1. Pré-requisitos

- VM Bare Metal (ou dedicada) com **Linux** (Ubuntu Server 22.04/24.04
  recomendado), **8GB de RAM**, acesso root/sudo.
- Os domínios `sso.rondonopolis.mt.gov.br` e `cofre.rondonopolis.mt.gov.br`
  já criados na zona DNS `rondonopolis.mt.gov.br`, prontos para apontar
  para o IP público da VM (você faz isso na seção 4.6, depois de saber o
  IP definitivo).
- Firewall/roteador com capacidade de liberar **apenas** as portas
  **80 e 443** de entrada para o IP público da VM.

### 4.2. Instalar o K3s + cert-manager (bootstrap único do cluster)

Conecte-se na VM (localmente ou via um acesso já existente — este é o
ÚNICO momento em que você toca a VM manualmente para instalar software de
infraestrutura; depois disso, a aplicação em si é 100% GitOps) e rode:

```bash
# 1) Instala o K3s como um único binário, já com Traefik e o
#    local-path-provisioner (storage) inclusos por padrão.
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644
  # ↑ Deixa o arquivo de credenciais do cluster (kubeconfig) legível pelo
  #   usuário comum que vai rodar o Self-Hosted Runner (evita ter que
  #   rodar o runner como root só para ler o kubeconfig).

# Confirma que o cluster subiu:
sudo k3s kubectl get nodes
# ↑ Deve mostrar 1 nó em status "Ready".
```

```bash
# 2) Instala o cert-manager (peça de infraestrutura, instalada uma única
#    vez — não faz parte do GitOps desta aplicação, assim como o próprio
#    K3s). Ele registra as CRDs (ClusterIssuer, Certificate) usadas por
#    k3s-cluster/cert-manager-issuer.yaml.
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Aguarde os Pods do cert-manager ficarem prontos (leva ~1 minuto):
kubectl get pods -n cert-manager -w
# ↑ Pressione Ctrl+C quando os 3 Pods (cert-manager, cainjector, webhook)
#   estiverem "Running" e "1/1 Ready".
```

> ℹ️ O instalador do K3s já vem com o **Traefik** (Ingress Controller) e o
> **Local Path Provisioner** (StorageClass `local-path`) habilitados por
> padrão — não é preciso instalar nada extra além do cert-manager acima
> para este projeto funcionar.

> ⚠️ **Sobre a NetworkPolicy (`network-policy.yaml`):** o K3s usa Flannel
> como CNI padrão, que **não enforça** NetworkPolicies (o recurso é
> aceito pelo cluster, mas não bloqueia tráfego de verdade). Isso não
> impede o deploy — é só uma camada de segurança que fica "adormecida"
> até você, opcionalmente, migrar para um CNI com suporte a enforcement
> (ex.: Calico). Veja o comentário completo dentro do próprio arquivo.

### 4.3. Configurar o `kubectl` para o usuário do Runner

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

### 4.4. Registrar o Self-Hosted Runner do GitHub Actions

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

### 4.5. Trocar as senhas fictícias (único ajuste de conteúdo pendente)

Os domínios (`sso.rondonopolis.mt.gov.br` e `cofre.rondonopolis.mt.gov.br`)
já estão configurados em `ingress.yaml`, `keycloak.yaml` e
`vaultwarden.yaml` — nada a fazer aí. O que ainda precisa de atenção antes
de ir para produção de verdade:

1. **Troque todas as senhas fictícias** em `k3s-cluster/secrets.yaml` (veja
   o passo a passo detalhado dentro do próprio arquivo — inclui como gerar
   senhas fortes com `openssl rand -base64 32`).
2. Edite `k3s-cluster/cert-manager-issuer.yaml` e troque o e-mail
   `ti@rondonopolis.mt.gov.br` pelo e-mail real da equipe de TI responsável
   (usado só para avisos administrativos do Let's Encrypt).
3. Aponte os registros DNS tipo **A** de `sso.rondonopolis.mt.gov.br` e
   `cofre.rondonopolis.mt.gov.br` para o IP público definitivo da VM.

### 4.6. Disparar o primeiro deploy

```bash
git add .
git commit -m "Ajusta segredos e e-mail do cert-manager para produção"
git push origin main
```

Acompanhe a execução em **Actions** no GitHub — o job `aplicar-manifestos`
vai rodar no seu runner self-hosted e aplicar os manifestos em ordem lógica:
Namespace → Secrets → PostgreSQL → NetworkPolicy → Backup CronJob →
Keycloak → Vaultwarden → ClusterIssuer (cert-manager) → Ingress.

> Se o DNS ainda não tiver propagado no momento deste primeiro deploy, o
> Ingress sobe normalmente (com certificado autoassinado temporário) e o
> cert-manager fica tentando emitir o certificado válido em segundo plano,
> sem bloquear o resto da stack — assim que o DNS propagar, ele completa
> sozinho, sem precisar rodar o workflow de novo.

### 4.7. Validar a implantação

```bash
kubectl get pods -n authentication -o wide
kubectl get ingress -n authentication
kubectl get certificate -n authentication
# ↑ Deve mostrar "auth-stack-tls-cert" com READY=True após alguns minutos.
```

Acesse `https://sso.rondonopolis.mt.gov.br` (deve mostrar a tela do
Keycloak) e `https://cofre.rondonopolis.mt.gov.br` (deve mostrar a tela do
Vaultwarden), ambos com cadeado válido no navegador.

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
| Ver status do certificado HTTPS | `kubectl describe certificate auth-stack-tls-cert -n authentication` |
| Forçar reaplicação dos manifestos | Aba **Actions** → workflow **Deploy Auth Stack para o K3s** → **Run workflow** |

---

## 6. Próximos passos recomendados (fora do escopo inicial)

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

---

**Dúvidas ou problemas?** Cada arquivo `.yaml` deste repositório tem
comentários explicando linha a linha o que cada parâmetro faz — comece por
lá antes de alterar qualquer valor.
