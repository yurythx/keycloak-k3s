# 🏛️ keycloak-k3s — Stack de Autenticação Governamental

Stack de autenticação e cofre de senhas, self-hosted, para uso institucional
(prefeitura), implantada em **K3s** via **GitOps** com **GitHub Actions** e
um **Self-Hosted Runner** — sem nunca expor SSH ou a API do Kubernetes para
a internet.

| Componente | Função | Réplicas |
|---|---|---|
| **Keycloak 26 (Quarkus)** | Identity Provider (SSO, OIDC/SAML) para todos os sistemas da prefeitura | 2 (alta disponibilidade) |
| **PostgreSQL 16-alpine** | Banco de dados persistente do Keycloak | 1 |
| **Vaultwarden** | Cofre de senhas (compatível com Bitwarden) para as equipes de TI/administração | 1 |
| **Traefik** | Ingress Controller (já incluso no K3s) — expõe os domínios públicos | — |

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
              ┌─────────────┴─────────────┐
              ▼                           ▼
   login.prefeitura.gov.br     cofres.prefeitura.gov.br
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
              │
   ┌──────────▼──────────┐
   │  Service: postgres   │
   └──────────┬──────────┘
   ┌──────────▼──────────┐
   │  Pod postgres         │
   │  (PVC dedicado 10Gi) │
   └──────────────────────┘
```

**Namespace único:** todos os recursos vivem dentro de `authentication`,
isolados do resto do cluster.

**Segurança de rede:** o Self-Hosted Runner do GitHub Actions roda DENTRO
da VM e abre uma conexão de **saída** para buscar trabalho na GitHub —
**nenhuma porta de entrada** (SSH, API do Kubernetes) precisa ficar exposta
publicamente. Só as portas **80 e 443** (tráfego web do Traefik) precisam
estar abertas no firewall/roteador.

**Persistência:** PostgreSQL e Vaultwarden gravam em **PersistentVolumeClaims**
usando a StorageClass `local-path` (já embutida no K3s), que grava
diretamente no disco físico da VM em `/var/lib/rancher/k3s/storage/`. Um
reinício de Pod, do K3s ou até da VM **não apaga os dados**.

---

## 2. Consumo de memória (por que cabe em 8GB de RAM)

| Processo | RAM (request) | RAM (limit) |
|---|---|---|
| Sistema Operacional + K3s (control-plane + kubelet) | ~800Mi | — |
| PostgreSQL | 256Mi | 512Mi |
| Keycloak (× 2 réplicas) | 600Mi cada (1200Mi total) | 1024Mi cada (2048Mi total) |
| Vaultwarden | 64Mi | 128Mi |
| Traefik (já incluso no K3s) | ~50Mi | — |
| **Total aproximado no pior caso (limits)** | | **~3,5 GiB** |

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
│       └── deploy.yml          # Pipeline GitOps (self-hosted runner)
├── k3s-cluster/
│   ├── namespaces.yaml         # Namespace "authentication"
│   ├── secrets.yaml            # Credenciais (Postgres, Keycloak, Vaultwarden)
│   ├── postgres-db.yaml        # PVC + Deployment + Service do PostgreSQL
│   ├── keycloak.yaml           # RBAC + Deployment (2 réplicas) + Service
│   ├── vaultwarden.yaml        # PVC + Deployment + Service do Vaultwarden
│   └── ingress.yaml            # Roteamento Traefik (domínios públicos)
└── README.md                   # Este arquivo
```

---

## 4. Passo a passo de implantação na VM

### 4.1. Pré-requisitos

- VM Bare Metal (ou dedicada) com **Linux** (Ubuntu Server 22.04/24.04
  recomendado), **8GB de RAM**, acesso root/sudo.
- Um domínio próprio (ex.: `prefeitura.gov.br`) com acesso ao painel de DNS
  para criar os registros `login.` e `cofres.`.
- Firewall/roteador com capacidade de liberar **apenas** as portas
  **80 e 443** de entrada para o IP público da VM.

### 4.2. Instalar o K3s (versão enxuta, sem componentes desnecessários)

Conecte-se na VM (localmente ou via um acesso já existente — este passo é
o ÚNICO momento em que você toca a VM manualmente; depois disso, tudo é
GitOps) e rode:

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

> ℹ️ O instalador do K3s já vem com o **Traefik** (Ingress Controller) e o
> **Local Path Provisioner** (StorageClass `local-path`) habilitados por
> padrão — não é preciso instalar nada extra para este projeto funcionar.

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

# Configura o runner, associando-o ao SEU repositório (token fornecido
# pela interface do GitHub, válido por tempo limitado).
./config.sh --url https://github.com/SEU_USUARIO/keycloak-k3s \
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

### 4.5. Ajustar os domínios e segredos antes do primeiro deploy

1. Edite `k3s-cluster/ingress.yaml` e troque `login.prefeitura.gov.br` /
   `cofres.prefeitura.gov.br` pelos domínios reais da prefeitura (se forem
   diferentes destes de exemplo).
2. Edite `k3s-cluster/keycloak.yaml`, variável `KC_HOSTNAME`, para o mesmo
   domínio usado no Ingress do Keycloak.
3. Edite `k3s-cluster/vaultwarden.yaml`, variável `DOMAIN`, para o mesmo
   domínio usado no Ingress do Vaultwarden.
4. **Troque todas as senhas fictícias** em `k3s-cluster/secrets.yaml` (veja
   o passo a passo detalhado dentro do próprio arquivo).
5. Configure os registros DNS tipo **A** apontando `login.` e `cofres.`
   para o IP público da VM.

### 4.6. Disparar o primeiro deploy

```bash
git add .
git commit -m "Deploy inicial da stack de autenticação"
git push origin main
```

Acompanhe a execução em **Actions** no GitHub — o job `aplicar-manifestos`
vai rodar no seu runner self-hosted e aplicar os manifestos na ordem:
Namespace → Secrets → PostgreSQL → Keycloak → Vaultwarden → Ingress.

### 4.7. Validar a implantação

```bash
kubectl get pods -n authentication -o wide
kubectl get ingress -n authentication
```

Acesse `https://login.prefeitura.gov.br` (deve mostrar a tela do Keycloak)
e `https://cofres.prefeitura.gov.br` (deve mostrar a tela do Vaultwarden).

---

## 5. Operações do dia a dia

| Tarefa | Comando |
|---|---|
| Ver logs do Keycloak | `kubectl logs -n authentication -l app=keycloak -f` |
| Ver logs do Postgres | `kubectl logs -n authentication deploy/postgres -f` |
| Reiniciar o Keycloak (após trocar segredo) | `kubectl rollout restart deployment/keycloak -n authentication` |
| Backup manual do banco | `kubectl exec -n authentication deploy/postgres -- pg_dump -U keycloak_admin keycloak > backup.sql` |
| Ver uso de RAM/CPU real dos Pods | `kubectl top pods -n authentication` |
| Forçar reaplicação dos manifestos | Aba **Actions** → workflow **Deploy Auth Stack para o K3s** → **Run workflow** |

---

## 6. Próximos passos recomendados (fora do escopo inicial)

- **cert-manager + Let's Encrypt**: para HTTPS com certificado confiável
  (o bloco `tls:` já está preparado e comentado em `ingress.yaml`).
- **Sealed Secrets / SOPS**: para versionar segredos criptografados no Git
  em vez de texto plano (ver aviso detalhado em `secrets.yaml`).
- **Backup automatizado** do PVC do Postgres e do Vaultwarden (ex.: via
  `CronJob` + envio para armazenamento externo/off-site).
- **MFA obrigatório** no realm do Keycloak para todos os administradores.
- **NetworkPolicy** restringindo que só o Keycloak fale com o Postgres
  (nenhum outro Pod do namespace precisa dessa comunicação).

---

**Dúvidas ou problemas?** Cada arquivo `.yaml` deste repositório tem
comentários explicando linha a linha o que cada parâmetro faz — comece por
lá antes de alterar qualquer valor.
