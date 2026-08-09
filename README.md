# 🏛️ keycloak-k3s — Stack de Autenticação Governamental (Prefeitura de Rondonópolis-MT)

Stack de autenticação e cofre de senhas, self-hosted, implantada em **K3s**
via **GitOps** com **GitHub Actions** e um **Self-Hosted Runner** — sem
nunca expor SSH ou a API do Kubernetes para a internet.

Este não é um projeto de "um serviço só": é a integração deliberada de
**seis peças que precisam funcionar em conjunto** — K3s, PostgreSQL,
Keycloak (clusterizado), Active Directory/LDAP, o Nginx de borda já
existente na rede da prefeitura, e o pipeline de GitOps que amarra tudo
isso a um `git push`. Cada uma dessas integrações foi **testada ao vivo no
cluster real** (não só escrita e assumida como correta) — a seção 7 lista
exatamente o que foi validado, como, e que evidência prova que funciona.

| Componente | Função | Réplicas | Domínio público | Porta na VM |
|---|---|---|---|---|
| **Keycloak 26 (Quarkus)** | Identity Provider (SSO, OIDC/SAML) para os sistemas da prefeitura, com federação de ~7.600 usuários reais do Active Directory | 2 (alta disponibilidade, cluster via DNS_PING) | `sso.rondonopolis.mt.gov.br` | `18443` |
| **PostgreSQL 16-alpine** | Banco de dados persistente do Keycloak (realms, usuários, sessões) | 1 | (interno, sem acesso externo) | — |
| **Vaultwarden** | Cofre de senhas (compatível com Bitwarden) para as equipes de TI/administração — hoje **não integrado** ao Keycloak (login próprio, separado — ver seção 7.6) | 1 | `cofre.rondonopolis.mt.gov.br` | `8081` |
| **Nginx (fora do K3s)** | Servidor de borda **já existente** na rede da prefeitura — termina o HTTPS público | — | recebe os 2 domínios acima | 80/443 |

Este repositório já está **100% pronto para ser aplicado na VM assim que
ela existir** — os domínios reais, o clustering do Keycloak, a federação
com o AD, o backup automático e a segmentação de rede já estão todos
configurados nos manifestos. O que falta é só a parte física (seção 5).

## Índice

1. [Arquitetura adotada](#1-arquitetura-adotada)
2. [Consumo de memória](#2-consumo-de-memória-por-que-cabe-em-8gb-de-ram)
3. [Estrutura do repositório](#3-estrutura-do-repositório)
4. [Isso funciona em outra VM? (portabilidade)](#4-isso-funciona-em-outra-vm-portabilidade)
5. [Passo a passo de implantação na VM](#5-passo-a-passo-de-implantação-na-vm)
6. [Operações do dia a dia](#6-operações-do-dia-a-dia)
7. [Integrações — o que conecta com o quê, e como foi validado](#7-integrações--o-que-conecta-com-o-quê-e-como-foi-validado)
8. [Problemas reais já encontrados e corrigidos](#8-problemas-reais-já-encontrados-e-corrigidos)
9. [Próximos passos recomendados](#9-próximos-passos-recomendados)

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
              │  🔒 NetworkPolicy: só Keycloak + backup acessam a porta 5432
   ┌──────────▼──────────┐
   │  Service: postgres    │
   └──────────┬──────────┘
   ┌──────────▼──────────┐         ┌────────────────────────┐
   │  Pod postgres          │◄─────┤ CronJob: backup diário  │
   │  (PVC dedicado 10Gi)   │      │ (pg_dump 03h, PVC 5Gi,  │
   └──────────────────────┘       │  retenção de 7 dias)    │
                                   └────────────────────────┘
                             ▲
                             │ LDAP (porta 389, sem TLS — ver seção 8)
                  ┌──────────┴──────────┐
                  │  Active Directory     │  Domain Controller da prefeitura
                  │  rondonopolis.local   │  (192.168.0.101) — fora do K3s,
                  │  (fora do K3s)        │  ~7.600 contas de usuário reais
                  └──────────────────────┘
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
`nginx-edge/README.md`. **Esta é uma decisão de migração, não uma
limitação técnica** — veja a seção 4 para a alternativa recomendada caso
você não tenha esse mesmo cenário de "substituir algo que já existe".

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
aceitar conexões vindas dos Pods do Keycloak e do CronJob de backup —
nenhum outro workload do namespace consegue alcançar o banco. Confirmado
ao vivo no cluster real que esta restrição é de fato aplicada pelo CNI
(ver seção 8 e `k3s-cluster/network-policy.yaml`).

**Backup:** um `CronJob` roda `pg_dump` todo dia às 03:00 (horário de
Rondonópolis-MT), compacta o resultado e mantém os últimos 7 dias
automaticamente, em um disco separado do disco de dados (ver limitação
sobre backup off-site em `k3s-cluster/postgres-backup-cronjob.yaml`).

**Federação com o Active Directory:** o Keycloak não gerencia usuários
manualmente — ele consulta o AD da prefeitura (`rondonopolis.local`) em
tempo real via LDAP, dentro de um Realm dedicado (`rondonopolis`,
separado do `master`). Ver seção 7.2 para o detalhamento completo.

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
│       └── deploy.yml                   # Pipeline GitOps (self-hosted runner, 14 passos)
├── scripts/
│   └── bootstrap-vm.sh                  # Script único: K3s + kubectl + runner
├── nginx-edge/                          # Cópia fiel do que já está no Nginx (referência, não aplicado)
│   ├── README.md
│   ├── sso.rondonopolis.mt.gov.br.conf
│   └── cofre.rondonopolis.mt.gov.br.conf
├── k3s-cluster/
│   ├── namespaces.yaml                  # Namespace "authentication"
│   ├── secrets.yaml                     # Credenciais (Postgres, Keycloak, Vaultwarden, AD)
│   ├── postgres-db.yaml                 # PVC + Deployment + Service do PostgreSQL
│   ├── keycloak.yaml                    # Service headless + Deployment + Services (interno + porta 18443) + tema
│   ├── keycloak-theme.yaml              # ConfigMap: tema visual customizado (logo/cores) da prefeitura
│   ├── vaultwarden.yaml                 # PVC + Deployment + Services (interno + porta 8081)
│   ├── network-policy.yaml              # Restringe acesso ao Postgres só ao Keycloak + backup
│   ├── postgres-backup-cronjob.yaml     # PVC + CronJob de backup diário do banco
│   └── ldap-federation-job.yaml         # Job: cria Realm "rondonopolis" + federação com o AD + admins + tema
└── README.md                            # Este arquivo
```

Cada arquivo `.yaml`/`.sh`/`.conf` tem comentários explicando **linha a
linha** o que cada parâmetro faz e, sempre que uma decisão não era óbvia,
o porquê dela — este README dá a visão de conjunto; os arquivos individuais
têm o detalhe técnico.

---

## 4. Isso funciona em outra VM? (portabilidade)

**Resumo:** sim, com ajustes — a arquitetura e a automação são genéricas
(K3s, GitOps, clustering do Keycloak, backup, NetworkPolicy), mas um
punhado de valores neste repositório é **especificamente calibrado para a
rede da Prefeitura de Rondonópolis-MT** e precisaria ser trocado antes de
implantar em qualquer outro lugar (outra VM, outro órgão, outro ambiente).
A tabela abaixo é a lista completa — não há nenhum outro valor
"escondido" fora dela.

### 4.1. Valores que PRECISAM mudar em uma VM/organização diferente

| O quê | Onde | Valor atual (Rondonópolis) | Por quê é específico |
|---|---|---|---|
| Hostname público do Keycloak | `keycloak.yaml` → `KC_HOSTNAME` | `https://sso.rondonopolis.mt.gov.br` | Domínio real desta prefeitura |
| IP confiável do proxy reverso | `keycloak.yaml` → `KC_PROXY_TRUSTED_ADDRESSES` | `192.168.0.218/32` (+ `10.42.0.0/16` interno, esse não muda) | IP do Nginx de borda **desta** rede |
| Hostname público do Vaultwarden | `vaultwarden.yaml` → `DOMAIN` | `https://cofre.rondonopolis.mt.gov.br` | Domínio real desta prefeitura |
| Porta legada do Keycloak | `keycloak.yaml` → Service `keycloak-external` | `18443` | Porta que o Nginx **desta** rede já espera (ver 4.2) |
| Porta legada do Vaultwarden | `vaultwarden.yaml` → Service `vaultwarden-external` | `8081` | Idem |
| Endereço do Domain Controller | `ldap-federation-job.yaml` → `AD_CONNECTION_URL` | `ldap://192.168.0.101:389` | IP do AD **desta** rede |
| Base DN dos usuários no AD | `ldap-federation-job.yaml` → `AD_USERS_DN` | `DC=rondonopolis,DC=local` | Estrutura do domínio AD **desta** prefeitura |
| Nome do Realm de destino | `ldap-federation-job.yaml` → `TARGET_REALM` | `rondonopolis` | Escolha de nome, livre para trocar |
| Grupos do AD com direito de admin | `ldap-federation-job.yaml` → `ADMIN_GROUP_NAMES` | `Domain Admins\|Departamento de Tecnologia da Informação` | Nomes reais de grupos **deste** AD |
| DN da conta de bind com o AD | `secrets.yaml` → `AD_BIND_DN` | `CN=<conta-servico-ad>,OU=...,DC=rondonopolis,DC=local` | Conta e estrutura de OUs **desta** prefeitura |
| Senha da conta de bind | Secret `ad-bind-credentials` (criado manualmente, **não** está no Git) | — | Sempre específica do ambiente, por design |
| Senha atual do `kc_admin` (para o Job de federação) | Secret `keycloak-admin-credentials` (criado manualmente, **não** está no Git) | — | Independente do `KC_BOOTSTRAP_ADMIN_PASSWORD` de `secrets.yaml` (esse só vale no primeiro boot) — ver seção 5.6 |
| Todas as senhas em `secrets.yaml` | `secrets.yaml` (`stringData`) | valores fictícios, claramente marcados | Devem ser geradas por ambiente — nunca reaproveitar |
| Vhosts do Nginx de borda | `nginx-edge/*.conf` | cópia fiel dos vhosts reais desta prefeitura | Documentação/referência — **não é aplicado por este repo**; em outra rede, o Nginx (se existir) teria sua própria config, gerenciada fora deste projeto |
| Dono/nome do repositório GitHub | `scripts/bootstrap-vm.sh` → `GH_OWNER`/`GH_REPO` | `yurythx`/`keycloak-k3s` | Já são variáveis de ambiente sobrepostas facilmente (`GH_OWNER=... GH_REPO=... ./bootstrap-vm.sh`) — não é preciso editar o script |

### 4.2. A decisão arquitetural que só faz sentido NESTE cenário

O ponto mais importante para quem for reusar este repositório em outro
lugar: **o esquema de "ocupar as mesmas portas legadas" (18443/8081) é uma
decisão de migração**, feita porque esta VM está substituindo um Keycloak
e um Vaultwarden bare-metal que já existiam, com um Nginx de borda gerido
por outra equipe que não podia (ou não devia precisar) ser reconfigurado.

Se o cenário de destino for **greenfield** (VM nova, sem nada rodando
antes, sem um Nginx externo já configurado), a recomendação é **não**
replicar esse esquema — em vez disso, usar o Traefik que já vem embutido
no K3s como Ingress Controller na porta 443, com um `cert-manager` para
emitir certificados automaticamente (Let's Encrypt). É mais simples,
mais padrão, e elimina a dependência de um Nginx externo por completo.
Essa mudança afetaria basicamente só `keycloak.yaml` e `vaultwarden.yaml`
(trocar `Service type: LoadBalancer` + portas custom por um `Ingress`
comum) — o resto do repositório (Postgres, backup, NetworkPolicy,
federação com AD, GitOps) é igualmente válido nos dois cenários.

### 4.3. O que NÃO muda entre ambientes (já é genérico)

- O mecanismo de instalação do K3s (`bootstrap-vm.sh`) — não tem nada
  específico de Rondonópolis, só espera uma VM Linux comum.
- O clustering do Keycloak via DNS_PING (headless Service +
  `JAVA_OPTS_APPEND`) — genérico para qualquer K3s.
- A estrutura da `NetworkPolicy` (rótulos `app: keycloak` /
  `app: postgres-backup`) — genérica, só depende dos próprios manifestos
  deste repositório.
- O mecanismo de injeção do tema visual via ConfigMap — genérico; o
  conteúdo do CSS/logo é que muda por organização (ver
  `keycloak-theme.yaml`).
- Toda a lógica do `deploy.yml` (ordem de aplicação, `wait`, tolerância a
  Secret ausente) — genérica.
- A filtragem de contas do AD (`objectCategory=person`, exclui contas de
  computador/serviço) — prática padrão de qualquer federação AD→Keycloak,
  não específica desta prefeitura.

### 4.4. Checklist rápido para implantar do zero em uma VM nova

1. Rode `scripts/bootstrap-vm.sh` (seção 5.2) — nenhuma edição necessária
   para esta parte.
2. Edite os 8 valores da tabela 4.1 que se aplicam ao seu caso (pule os de
   AD se não for federar com um Active Directory).
3. Decida entre manter o esquema de portas legadas (4.1) ou migrar para
   Ingress+cert-manager (4.2) — **isso não é automático**, é uma escolha
   consciente de arquitetura.
4. Gere segredos novos e reais em `secrets.yaml` (nunca reaproveite os
   valores fictícios deste repositório).
5. Crie manualmente o Secret `ad-bind-credentials` (se for usar federação
   com AD) — é o único segredo que propositalmente não vive no Git.
6. `git push` — o resto é automático.

---

## 5. Passo a passo de implantação na VM

### 5.1. Pré-requisitos

- VM Bare Metal/Proxmox com **Linux** (Ubuntu Server 22.04/24.04
  recomendado), **8GB de RAM**, acesso root/sudo.
- Conectividade de rede entre esta VM e o servidor **Nginx da borda**
  (mesma VLAN/sub-rede) — a VM só precisa aceitar conexões do Nginx nas
  portas 18443 e 8081.
- Os domínios `sso.rondonopolis.mt.gov.br` e `cofre.rondonopolis.mt.gov.br`
  já existiam em produção antes (Keycloak/Vaultwarden bare-metal) — o DNS
  já deve estar correto, apontando para o IP público do Nginx da borda.
- Se for federar com o Active Directory: conectividade da VM até o Domain
  Controller na porta 389 (ou 636, se/quando LDAPS for habilitado — ver
  seção 8).

### 5.2. Opção A (recomendada): script único de bootstrap automatizado

Em vez de digitar os comandos das seções 5.3 a 5.4 um por um, o script
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

# Opção sem registro automático do runner (registra na mão depois, seção 5.5):
sudo ./scripts/bootstrap-vm.sh

# Opção com registro automático do runner — gere antes um Personal Access
# Token em GitHub: Settings → Developer settings → Personal access tokens →
# Fine-grained → permissão "Administration: Read and write" NO REPOSITÓRIO
# keycloak-k3s (não precisa de acesso a outros repositórios):
sudo GH_PAT="ghp_xxx_seu_token" ./scripts/bootstrap-vm.sh
```

O script imprime, ao final, exatamente o que ainda falta fazer fora dele
(editar segredos) — pule direto para a seção 5.6.

> O token (`GH_PAT`) só é usado em memória, na hora de chamar a API do
> GitHub para pegar um token de registro temporário (válido ~1h) — nunca é
> salvo em disco pelo script. Prefira um token com validade curta (ex.: 7
> dias) e revogue-o depois de usar, se quiser ser ainda mais conservador.

Se preferir entender/rodar cada comando manualmente (ou se algo no script
falhar e você precisar diagnosticar um passo específico), siga a **Opção B**
abaixo — é exatamente o que o script automatiza por baixo dos panos.

### 5.3. Opção B: instalar o K3s manualmente

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

> ✅ **Sobre a NetworkPolicy (`network-policy.yaml`):** testado ao vivo no
> cluster real — o K3s atual já **aplica** NetworkPolicies de verdade
> (bloqueia tráfego, não é só declarativo). Na prática, isso significa que
> qualquer novo Pod que precise falar com o PostgreSQL só consegue se
> tiver um dos rótulos explicitamente liberados no arquivo (`app:
> keycloak` ou `app: postgres-backup`) — esquecer esse detalhe já causou
> um bug real neste projeto (backups vazios, ver seção 8). Veja o
> comentário completo dentro do próprio arquivo.

### 5.4. Configurar o `kubectl` para o usuário do Runner

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

### 5.5. Registrar o Self-Hosted Runner do GitHub Actions

> Pule esta seção se você já rodou o script da seção 5.2 com `GH_PAT`
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

### 5.6. Ajustes finais de conteúdo (antes do primeiro deploy)

Os domínios, IPs (VM `192.168.0.225`, Nginx da borda `192.168.0.218`) e as
portas legadas (`18443`/`8081`) já estão preenchidos em `keycloak.yaml` e
`vaultwarden.yaml` — nada a fazer aí **nesta VM específica** (se for outra
VM/organização, veja a tabela completa na seção 4.1). O que ainda precisa
de atenção:

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
3. **Federação com o Active Directory**: automatizada via
   `k3s-cluster/ldap-federation-job.yaml` (um Job que roda `kcadm.sh` e,
   de forma idempotente, a cada deploy) — ver seção 7.2 para o
   funcionamento completo.

   Dois passos manuais necessários — criar, uma única vez, dois Secrets que
   NUNCA são commitados no Git (a pipeline tolera a ausência deles: o passo
   é pulado sem derrubar o resto do deploy, até você criá-los e rodar o
   workflow de novo):
   ```bash
   # 1) Senha da conta de bind com o AD:
   kubectl create secret generic ad-bind-credentials \
     --namespace authentication \
     --from-literal=AD_BIND_PASSWORD='SENHA_REAL_DA_CONTA_ADM_YURI'

   # 2) Senha ATUAL do admin do Keycloak (kc_admin) — usada pelo Job para se
   #    autenticar a cada execução. IMPORTANTE: isto é INDEPENDENTE do
   #    KC_BOOTSTRAP_ADMIN_PASSWORD em secrets.yaml (que só vale no
   #    primeiríssimo boot do Keycloak) — sempre que trocar a senha real do
   #    kc_admin via kcadm (ver secrets.yaml), atualize também este Secret,
   #    ou o Job volta a falhar na autenticação no próximo deploy:
   kubectl create secret generic keycloak-admin-credentials \
     --namespace authentication \
     --from-literal=KC_ADMIN_PASSWORD='SENHA_ATUAL_DO_KC_ADMIN'
   ```

> 💡 **Onde testar login** (achado comum): o Admin Console padrão
> (`/admin/master/console/`) só reconhece usuários do realm `master` —
> um usuário do AD ou o `prefeitura` NUNCA vão logar ali, é esperado dar
> "user not found". Teste no realm certo:
> `https://sso.rondonopolis.mt.gov.br/admin/rondonopolis/console/` (Admin
> Console do realm rondonopolis) ou
> `https://sso.rondonopolis.mt.gov.br/realms/rondonopolis/account/`
> (tela de conta do usuário comum).

> ⚠️ **Duas pendências conhecidas na integração com o AD** (detalhe
> completo na seção 7.2 e no cabeçalho de `ldap-federation-job.yaml`):
> 1. Conexão sem criptografia (LDAP, porta 389) — DC ainda sem certificado
>    configurado para LDAPS/StartTLS.
> 2. Conta de bind administrativa (`<conta-servico-ad>`) em vez de uma conta de
>    serviço dedicada só leitura.

### 5.7. Disparar o primeiro deploy

```bash
git add .
git commit -m "Ajusta segredos para producao"
git push origin main
```

Acompanhe a execução em **Actions** no GitHub — o job `aplicar-manifestos`
vai rodar no seu runner self-hosted e aplicar os manifestos em ordem lógica:
Namespace → Secrets → PostgreSQL → NetworkPolicy → Backup CronJob → tema
do Keycloak → Keycloak → Vaultwarden → federação com o AD.

### 5.8. Validar a implantação

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

## 6. Operações do dia a dia

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
| Reprocessar a federação com o AD manualmente | `kubectl delete job ldap-federation-setup -n authentication --ignore-not-found && kubectl apply -f k3s-cluster/ldap-federation-job.yaml` |
| Ver o resultado da última sincronização com o AD | `kubectl logs -n authentication job/ldap-federation-setup` |

---

## 7. Integrações — o que conecta com o quê, e como foi validado

Esta seção existe porque "escrever um YAML que parece certo" e "confirmar
que a integração funciona de verdade" são coisas diferentes — cada item
abaixo foi testado ao vivo contra o cluster e/ou o AD reais desta
prefeitura, não apenas assumido a partir da documentação oficial das
ferramentas.

### 7.1. PostgreSQL ↔ Keycloak

O Keycloak se conecta ao Postgres via o nome do Service Kubernetes
(`postgres`, resolvido por DNS interno do cluster), usando as credenciais
do Secret `auth-stack-credentials`. **Validado**: os Pods do Keycloak só
ficam com status `Ready` depois de rodar com sucesso as migrations do
banco na primeira inicialização (visível nos logs, `kubectl logs -n
authentication -l app=keycloak`) — se a conexão falhasse, o Pod ficaria
preso em `CrashLoopBackOff`, o que não acontece no cluster real.

### 7.2. Active Directory (LDAP) ↔ Keycloak

A integração mais complexa do projeto, feita via `ldap-federation-job.yaml`
— um Job que roda `kcadm.sh` (CLI oficial de administração do Keycloak) de
forma **idempotente** a cada deploy:

1. Cria o Realm `rondonopolis` (separado do `master`, onde só administram
   quem precisa administrar a infraestrutura do próprio Keycloak).
2. Cria um provedor de identidade LDAP apontando para o Domain Controller
   (`192.168.0.101:389`), com `customUserSearchFilter=(objectCategory=person)`
   para trazer só contas de usuário reais — excluindo automaticamente
   contas de computador/serviço que também vivem no mesmo diretório.
3. Sincroniza grupos do AD via um `group-ldap-mapper`.
4. Concede a role `realm-admin` (administrador só deste realm, não do
   Keycloak inteiro) a qualquer usuário que pertença aos grupos AD
   `Domain Admins` ou `Departamento de Tecnologia da Informação`.
5. Cria um usuário local `prefeitura` (não federado do AD) como conta de
   emergência — funciona mesmo se o AD estiver fora do ar.
6. Ativa o tema visual customizado (`prefeitura`) no realm.

**Validado ao vivo**, com evidências concretas:
- Sincronização real trouxe **7.608 usuários** genuínos do AD (confirmado
  contando registros, não só "o Job terminou sem erro").
- Testado que o filtro `objectCategory=person` é necessário: sem ele, a
  primeira tentativa trouxe **5.797 contas de computador/serviço** junto
  (bug real, corrigido — ver seção 8).
- Login de um usuário real do AD testado e funcionando no realm certo.
- Concessão de `realm-admin` aos dois grupos verificada não só pelo
  `kcadm.sh get-roles`, mas diretamente pelo endpoint REST
  `groups/{id}/role-mappings/clients/{clientId}`, porque o primeiro se
  mostrou pouco confiável para roles de cliente em alguns casos.
- Usuário local `prefeitura` testado com login real, senha resetada e
  reconfirmada ao vivo.

Pendências conhecidas: conexão ainda sem TLS (porta 389, não 636 — o DC não
tem certificado configurado para LDAPS/StartTLS, testado diretamente com
`openssl s_client` e `ldapsearch -ZZ`) e uso de uma conta administrativa
(`<conta-servico-ad>`) como conta de bind, em vez de uma conta de serviço dedicada só
leitura. **Esta segunda pendência já deixou de ser só teórica**: essa conta
tem uma restrição de horário de logon configurada no próprio AD, e fora da
janela permitida o Keycloak não consegue nem abrir a conexão LDAP — o que
já derrubou a federação inteira (não só o login pessoal do `<conta-servico-ad>`) numa
madrugada real de teste. Ver seção 8 para os detalhes e a seção 9 para a
prioridade elevada de correção.

### 7.3. Nginx (borda, fora do K3s) ↔ K3s

O Nginx que já existe na rede da prefeitura não foi tocado — nenhuma linha
de configuração dele foi alterada. Em vez disso, o K3s foi configurado
para ocupar as MESMAS portas (`18443` para o Keycloak, `8081` para o
Vaultwarden) que os serviços bare-metal antigos ocupavam, via `Service`
do tipo `LoadBalancer` com `externalTrafficPolicy: Local` (preserva o IP
real de quem conecta, importante para auditoria/logs — só funciona porque
o cluster é single-node).

**Validado**: `curl -I` local na VM contra `localhost:18443` e
`localhost:8081` respondendo corretamente, e — mais importante — acesso
real via navegador aos domínios públicos (`https://sso.rondonopolis.mt.gov.br`
e `https://cofre.rondonopolis.mt.gov.br`) funcionando de ponta a ponta
através do Nginx real, sem qualquer alteração nele.

### 7.4. GitHub Actions (Self-Hosted Runner) ↔ K3s

O runner roda dentro da própria VM e se autentica na API do Kubernetes
usando o kubeconfig local do K3s — não há credencial nenhuma trafegando
pela internet para isso. A conexão com o GitHub é sempre de **saída**
(o runner "puxa" trabalho, o GitHub nunca "empurra" para dentro da rede
da prefeitura), então nenhuma porta de entrada precisa ser aberta no
firewall.

**Validado**: múltiplos deploys reais rodados de ponta a ponta (`git push`
→ pipeline aplica os manifestos → recursos atualizados no cluster),
incluindo a correção de bugs descobertos durante este mesmo processo de
verificação (seção 8).

### 7.5. CronJob de backup ↔ PostgreSQL

Ver seção 8 — esta integração **estava quebrada silenciosamente** (backups
vazios) e foi corrigida e re-validada durante esta auditoria, com teste
real: `kubectl create job --from=cronjob/postgres-backup`, confirmando um
arquivo `.sql.gz` de conteúdo real (não vazio) no volume persistente
dedicado.

### 7.6. Vaultwarden — hoje NÃO integrado ao Keycloak (e não é só falta de configurar)

Importante deixar explícito: o Vaultwarden está implantado **lado a lado**
com o Keycloak (mesmo namespace, mesmo cluster, mesmo Nginx de borda),
mas não há **nenhuma integração de login** entre os dois — o Vaultwarden
usa seu próprio sistema de contas/senhas, totalmente independente do Realm
`rondonopolis` ou do AD. Quem for administrar ambos precisa de duas
credenciais separadas.

**Testado ao vivo e descartado** (não é um "próximo passo" pendente, é uma
limitação real do software): a API do Vaultwarden expõe um campo `sso` em
`/api/config`, o que sugeriu suporte a OpenID Connect — mas configurar
`SSO_ENABLED`/`SSO_AUTHORITY`/`SSO_CLIENT_ID`/`SSO_CLIENT_SECRET` e
reiniciar não teve NENHUM efeito, em duas versões testadas (a que roda em
produção, `1.32.5`, e a mais recente disponível na época, `1.37.1`,
testada isolada em um Pod descartável): nenhuma rota de OIDC/SSO aparece
na lista de rotas que o próprio Vaultwarden imprime ao subir, e o campo
`sso` continua vazio de qualquer forma. Esse campo existe só por
compatibilidade de schema com o cliente oficial do Bitwarden — não há
implementação de SSO no servidor do Vaultwarden self-hosted. É uma
limitação de arquitetura do Bitwarden/Vaultwarden (o cofre é decifrado no
cliente com a senha mestra; o fluxo completo de SSO com chave de
decriptação separada é um recurso pago do Bitwarden Enterprise/Cloud, não
reimplementado no Vaultwarden).

Alternativas reais, se algum dia isso voltar à pauta:
- **Proxy de pré-autenticação** (ex.: `oauth2-proxy`) na frente do
  Vaultwarden, exigindo login no Keycloak/AD antes de sequer alcançar a
  tela de login do Vaultwarden — não é SSO (a senha mestra do cofre
  continua sendo digitada depois, separada), é uma camada extra de portão.
- Manter como está — dois logins separados é, na prática, também um
  padrão de segurança defensável para um gerenciador de senhas (evita
  depender de uma única credencial comprometida para expor o cofre
  inteiro).

---

## 8. Problemas reais já encontrados e corrigidos

Esta stack não foi só escrita — foi **testada em produção real**, e vários
comportamentos "óbvios" da documentação oficial se mostraram diferentes na
prática. Registrar isso aqui evita repetir a mesma investigação:

| Problema | Sintoma | Causa raiz | Correção |
|---|---|---|---|
| Keycloak em `CrashLoopBackOff` | Pod reiniciando sem parar | Flag `--optimized` exige uma imagem pré-otimizada em build, e a imagem oficial usada aqui não é | Trocado para `start` (sem `--optimized`) |
| `KC_CACHE=ha` inválido | Erro de configuração ao subir | `ha` não é um valor válido nesta versão — o correto é `ispn` | `KC_CACHE=ispn`, removida a referência a um `cache-ha.xml` que nunca existiu de fato |
| Cluster do Keycloak nunca formava | 2 réplicas rodando isoladas, sem se enxergar | KUBE_PING (RBAC) foi a primeira tentativa e é o mecanismo errado para este cenário | Trocado para DNS_PING: Service headless + `JAVA_OPTS_APPEND=-Djgroups.dns.query=...` |
| Runner registrado no diretório errado | `RUNNER_DIR` apontando para `/root` mesmo rodando como usuário comum | Calculado a partir de `$HOME` ANTES de resolver o usuário real por trás do `sudo` | Recalculado depois de resolver `TARGET_HOME` via `SUDO_USER`/`getent passwd` |
| Pipeline disparando 3x seguidas | Vários deploys enfileirados rodando em sequência | `concurrency.cancel-in-progress: false` deixava execuções antigas na fila | Trocado para `true` |
| LDAPS/StartTLS falhando no AD | `errno=104` (reset de conexão) / `ldap_start_tls: Server is unavailable (52)` | DC sem certificado configurado para o serviço LDAP | Decisão consciente: LDAP simples (389) por enquanto — ver seção 7.2 |
| Sincronização trazendo "usuários" errados | 5.797 contas de computador/serviço junto com os usuários reais | Faltava o filtro `objectCategory=person` no provedor LDAP | Adicionado `customUserSearchFilter=["(objectCategory=person)"]` |
| Script do Job de federação falhando silenciosamente / duplicando recursos | Múltiplos providers LDAP e mappers duplicados criados em execuções sucessivas | A imagem oficial do Keycloak (UBI-minimal) **não tem `awk`** — o script usava `awk` para parsear a saída do `kcadm.sh`, e isso só funcionava quando testado no shell da VM, não dentro do container do Job | Reescrito com uma função pura em bash (`find_id_by_exact_name`), sem depender de `awk`/`curl`/`tar`/`jq`, nenhum dos quais existe na imagem |
| Backups aparentemente OK, mas vazios | Arquivos `.sql.gz` de ~20 bytes, log dizendo "Backup concluído (4.0K)" | Dois problemas combinados: (1) o Pod do CronJob não tinha rótulo permitido pela `NetworkPolicy`, sendo bloqueado de acessar o Postgres; (2) o script usava `pg_dump \| gzip`, e em um pipe o `set -e` só vê o código de saída do ÚLTIMO comando (`gzip`), então uma falha do `pg_dump` passava despercebida | Adicionado o rótulo `app: postgres-backup` + regra correspondente na `NetworkPolicy`; script reescrito para separar `pg_dump` de `gzip` e checar o tamanho mínimo do arquivo gerado (ver commit que corrigiu isto) |
| Suposição sobre NetworkPolicy no Flannel | Documentação afirmava que o Flannel do K3s não aplica NetworkPolicies | Suposição baseada em documentação genérica, nunca testada neste cluster específico | Testado ao vivo (par de Pods com/sem o rótulo certo tentando alcançar o Postgres) — a suposição estava **errada**: este cluster aplica a política de verdade. Documentação corrigida em todo o repositório |
| `kubectl cp` falhando ao inspecionar o tema do Keycloak | Erro ao tentar extrair o JAR do tema de dentro do Pod | A imagem também não tem `tar`, usado internamente pelo `kubectl cp` | Extração feita com `kubectl exec ... -- cat arquivo > arquivo_local` (redirecionamento puro de stdout, funciona até para binário) |
| **Login do AD inteiro parava de funcionar durante a madrugada** | `<conta-servico-ad>` e QUALQUER usuário do AD recebiam erro ao logar, de forma intermitente | O próprio Active Directory rejeitava a conta de bind (`<conta-servico-ad>`) com `LDAP error 49, data 530` — código padrão do Windows para "restrição de horário de logon" (`ERROR_INVALID_LOGON_HOURS`). Como essa MESMA conta é usada para toda consulta do Keycloak ao AD, o bloqueio derrubava a federação inteira, não só o login pessoal do `<conta-servico-ad>`. Reproduzido de forma independente com `ldapsearch` direto no DC (sem o Keycloak no meio) | Causa raiz fora do alcance deste repositório (é uma política do AD) — reportado ao time do AD como ação pendente (ver seção 9). Reforça a prioridade de trocar a conta de bind por uma conta de serviço dedicada, sem essa restrição |
| Conta local `prefeitura` (break-glass) também parava de logar | `invalid_grant: "Account is not fully set up"`, mesmo com usuário/senha corretos e `requiredActions` vazio no usuário | O realm tem a ação `VERIFY_PROFILE` habilitada por padrão (comportamento de fábrica do Keycloak 26) — o usuário `prefeitura` era criado sem e-mail, e essa ação é recalculada dinamicamente a cada login (não fica salva na lista de ações pendentes do usuário) | `ldap-federation-job.yaml` agora define um e-mail (`PREFEITURA_EMAIL`) na criação do usuário, e reforça isso em TODO deploy (idempotente) — corrige automaticamente qualquer cluster que já tenha rodado uma versão anterior deste Job |
| Probes do Postgres citavam um usuário que nunca existiu | `pg_isready -U keycloak_admin` nas probes e na documentação de restore | Copiado de um ambiente de referência diferente — o usuário real (`secrets.yaml` → `POSTGRES_USER`) sempre foi `keycloak_user` | Corrigido em `postgres-db.yaml` (readiness/liveness) e no comentário de restore de `postgres-backup-cronjob.yaml`. Não derrubava as probes (`pg_isready` não valida credencial, só conectividade — confirmado ao vivo), mas quebraria um `psql -U keycloak_admin` real, copiado por alguém em uma emergência |
| Pipeline podia "mascarar" uma falha real da federação com o AD | Passo 13 do `deploy.yml` sempre terminava em sucesso (verde), mesmo quando o Job de federação falhava de verdade (não só por Secret ausente) | `kubectl wait ... \|\| kubectl logs ...`: `kubectl logs` quase sempre funciona mesmo para um Job que falhou, então o `\|\|` "engolia" o erro | Reescrito para checar o resultado do `kubectl wait` explicitamente e `exit 1` se o Job realmente falhar — a pipeline agora fica corretamente vermelha nesse caso |
| 🔴 **Senha fictícia do superadmin (`kc_admin`) ativa em produção por semanas** | O valor de `KC_BOOTSTRAP_ADMIN_PASSWORD` em `secrets.yaml` — literalmente escrito como placeholder, com "Tr0c4r" (trocar) no próprio valor — ainda funcionava para logar como `kc_admin` (dono de TODOS os realms), mesmo dias depois do deploy inicial | Essa variável só é lida pelo Keycloak no PRIMEIRÍSSIMO boot — depois disso, editar o arquivo e dar `git push` não muda mais nada (diferente de `POSTGRES_PASSWORD`, que É relida a cada reinício). O comentário original dizia "troque assim que logar" mas não deixava claro que editar o YAML não tem efeito nenhum para esta variável específica | Senha trocada de verdade via `kcadm.sh set-password` (o único jeito que funciona pós-boot); comentário em `secrets.yaml` reescrito explicando o mecanismo e com os comandos exatos de troca, para não se repetir |
| 🔴 **Trocar a senha do `kc_admin` quebrava o Job de federação no deploy seguinte** | `ldap-federation-setup` passava a falhar logo após "Logging into..." — reproduzido ao vivo minutos depois de trocar a senha do `kc_admin` (ver bug acima) | O Job lia a senha do MESMO campo `KC_BOOTSTRAP_ADMIN_PASSWORD` de `secrets.yaml` para se autenticar a cada execução — mas esse arquivo é reaplicado pela pipeline em TODO deploy (step 4), sempre com o valor fictício, desfazendo qualquer troca real feita via `kcadm` | O Job agora lê a senha de um Secret SEPARADO (`keycloak-admin-credentials`), criado manualmente e nunca recriado pela pipeline — igual ao padrão já usado para `ad-bind-credentials`. `deploy.yml` (passo 13) passou a tolerar também a ausência deste novo Secret |
| Timeout do passo de federação curto demais (mascarado até corrigir o bug acima) | Pipeline falhava com "não completou a tempo", mesmo com o Job terminando com sucesso poucos segundos depois, por conta própria | O Job de federação, com sync real de grupos do AD pela rede, leva ~3-4 minutos — mais que o `kubectl wait --timeout=120s` da pipeline. Esse timeout curto sempre existiu, mas ficava escondido pelo bug do `kubectl wait \|\| kubectl logs` (linha acima na tabela) — corrigir um revelou o outro | Timeout do passo elevado para 300s (alinhado com o `activeDeadlineSeconds: 300` já definido no próprio Job), e o teto geral da pipeline (`timeout-minutes`) elevado de 10 para 20 para acomodar a soma de todos os `kubectl wait` no pior caso |

**Padrão comum por trás da maioria destes problemas**: a imagem oficial do
Keycloak 26 (baseada em UBI-minimal) é muito mais enxuta do que se costuma
assumir — **não tem** `curl`, `awk`, `tar`, `unzip`, `python3`, `perl` nem
`jq`, só `bash`/`sh`/`grep`/`sed`/`cut`/`tr`/`java`. Qualquer script que
rode dentro de um container baseado nela (como o Job de federação com o
AD) precisa ser escrito considerando essa limitação — testar "no shell da
VM" não é a mesma coisa que testar "dentro do container", e essa diferença
já causou bugs reais neste projeto.

---

## 9. Próximos passos recomendados

- **Certificado LDAPS no Domain Controller**: a federação com o AD já está
  automatizada (`ldap-federation-job.yaml`), mas roda hoje sem
  criptografia (LDAP, porta 389) porque o DC não tem certificado
  configurado para o serviço LDAP — pedir ao time que administra o AD
  para configurar isso, e então trocar a URL de conexão para
  `ldaps://192.168.0.101:636`.
- **🔴 PRIORIDADE ELEVADA — Conta de bind dedicada para o AD**: hoje usa uma
  conta administrativa (`<conta-servico-ad>`) por conveniência. Isso deixou de ser só
  uma recomendação de boas práticas: já causamos uma indisponibilidade REAL
  do login inteiro do realm `rondonopolis` porque essa conta tem uma
  restrição de horário de logon no AD (`data 530` / `ERROR_INVALID_LOGON_HOURS`)
  — fora da janela permitida, o Keycloak não consegue nem abrir a conexão
  LDAP, e NINGUÉM do AD consegue logar (ver seção 8). Ação recomendada:
  pedir ao time do AD uma conta de serviço dedicada, só leitura, SEM
  restrição de horário — depois trocar `AD_BIND_DN` em `secrets.yaml` e
  recriar o Secret `ad-bind-credentials` com a senha da nova conta.
- **Sealed Secrets / SOPS**: para versionar segredos criptografados no Git
  em vez de texto plano (ver aviso detalhado em `secrets.yaml`).
- **Backup off-site**: o CronJob já grava backups diários no disco da VM
  (e agora, de fato, com conteúdo real — ver seção 8), mas uma cópia
  adicional para fora da VM (outro datacenter/nuvem) é necessária para
  proteger contra perda física do servidor — ver limitação detalhada em
  `postgres-backup-cronjob.yaml`.
- **MFA obrigatório** no realm do Keycloak para todos os administradores.
- **Tema visual da prefeitura**: o mecanismo já está pronto e ativo
  (`keycloak-theme.yaml`), falta só o arquivo de logo e as cores
  institucionais oficiais para deixar de ser um esqueleto visualmente
  idêntico ao tema padrão.
- ~~Login unificado do Vaultwarden via OIDC~~ — **investigado e descartado**
  (ver seção 7.6): o Vaultwarden self-hosted não tem suporte real a SSO,
  testado ao vivo em duas versões. Decisão consciente: manter os dois
  sistemas de credenciais separados como estão.
- **Monitorar a validade do certificado** gerenciado pelo Nginx da borda
  (fora do escopo deste repositório, mas crítico — um certificado vencido
  ali derruba o HTTPS de toda a stack).

---

**Dúvidas ou problemas?** Cada arquivo `.yaml`/`.sh`/`.conf` deste
repositório tem comentários explicando linha a linha o que cada parâmetro
faz — comece por lá antes de alterar qualquer valor. Para problemas já
vividos e resolvidos, veja a seção 8 antes de investigar do zero.
