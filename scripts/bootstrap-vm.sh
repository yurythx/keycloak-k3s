#!/usr/bin/env bash
# ==============================================================================
# ARQUIVO: scripts/bootstrap-vm.sh
# ------------------------------------------------------------------------------
# OBJETIVO
#   Automatizar TUDO que é instalação de software na VM (o que antes era feito
#   copiando/colando comandos manualmente, seção 4.2-4.4 do README.md):
#     1. Instalar o K3s.
#     2. Instalar o cert-manager (HTTPS automático via Let's Encrypt).
#     3. Configurar o kubectl para o seu usuário comum (sem precisar de root).
#     4. Registrar e iniciar o Self-Hosted Runner do GitHub Actions.
#
#   É IDEMPOTENTE: rodar de novo depois de já ter rodado uma vez não quebra
#   nada — cada etapa verifica se já foi feita antes de agir.
#
# O QUE ESTE SCRIPT **NÃO** FAZ (e por quê)
#   - Port-forward das portas 80/443 no roteador/firewall de borda: depende
#     do seu roteador/Proxmox especificamente, que este script não consegue
#     alcançar nem identificar automaticamente.
#   - Criar os registros DNS (sso.rondonopolis.mt.gov.br / cofre.…): depende
#     do provedor de DNS da prefeitura (painel próprio, Registro.br, etc.),
#     que também está fora do alcance deste script.
#   - Trocar as senhas fictícias em k3s-cluster/secrets.yaml e o e-mail em
#     k3s-cluster/cert-manager-issuer.yaml: são decisões de conteúdo, não de
#     infraestrutura — continuam sendo editadas no repositório (fora da VM)
#     e enviadas via `git push`, como manda o GitOps.
#
# COMO USAR
#   1. Copie este script para a VM (scp, git clone do repositório, etc.).
#   2. Dê permissão de execução:
#        chmod +x scripts/bootstrap-vm.sh
#   3. Rode com sudo (precisa de root para instalar o K3s e o cert-manager):
#
#        sudo ./scripts/bootstrap-vm.sh
#
#      Para TAMBÉM registrar o runner automaticamente (passo 4), gere um
#      Personal Access Token no GitHub (Settings → Developer settings →
#      Personal access tokens → Fine-grained → dê permissão "Administration:
#      Read and write" NO REPOSITÓRIO keycloak-k3s) e rode:
#
#        sudo GH_PAT="ghp_xxx_seu_token" ./scripts/bootstrap-vm.sh
#
#      Sem GH_PAT, o script faz os passos 1-3 (cluster) e imprime as
#      instruções manuais do runner no final, sem quebrar a execução.
#
#      ⚠️ O token é usado apenas em memória para chamar a API do GitHub e
#      buscar um token de registro TEMPORÁRIO (válido por ~1h) — ele nunca é
#      salvo em disco por este script. Ainda assim, prefira um Fine-grained
#      PAT com validade curta (ex.: 7 dias) em vez de um Classic PAT amplo.
# ==============================================================================

set -euo pipefail
# ↑ `set -e`: aborta o script no primeiro comando que falhar (exit != 0).
#   `set -u`: trata uso de variável não definida como erro (evita typos
#   silenciosos, ex.: usar $GH_OWMER em vez de $GH_OWNER).
#   `set -o pipefail`: em um pipe (`cmd1 | cmd2`), o exit code do PIPE
#   inteiro passa a ser o do primeiro comando que falhar, não só o último —
#   sem isso, um `curl` que falha silenciosamente antes de um `| tar` faria
#   o script achar que deu tudo certo.

# ------------------------------------------------------------------------------
# Configuráveis via variável de ambiente (todas têm um valor padrão sensato)
# ------------------------------------------------------------------------------
GH_OWNER="${GH_OWNER:-yurythx}"
# ↑ Dono do repositório no GitHub (usuário ou organização).

GH_REPO="${GH_REPO:-keycloak-k3s}"
# ↑ Nome do repositório onde o Self-Hosted Runner será registrado.

RUNNER_NAME="${RUNNER_NAME:-$(hostname)-k3s}"
# ↑ Nome de exibição do runner na interface do GitHub. Por padrão, usa o
#   hostname da VM + sufixo "-k3s" para ficar fácil de identificar.

RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"
# ↑ Pasta onde o agente do runner será instalado.

GH_PAT="${GH_PAT:-}"
# ↑ Personal Access Token opcional — se vazio, o passo 4 (runner) é pulado
#   com instruções manuais impressas no final.

# ------------------------------------------------------------------------------
# Cores para deixar a saída do script mais fácil de ler nos logs
# ------------------------------------------------------------------------------
COR_INFO='\033[1;34m'   # azul
COR_OK='\033[1;32m'     # verde
COR_AVISO='\033[1;33m'  # amarelo
COR_RESET='\033[0m'

log_info()  { echo -e "${COR_INFO}[INFO]${COR_RESET} $*"; }
log_ok()    { echo -e "${COR_OK}[OK]${COR_RESET} $*"; }
log_aviso() { echo -e "${COR_AVISO}[AVISO]${COR_RESET} $*"; }

# ------------------------------------------------------------------------------
# Verificações iniciais
# ------------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  # ↑ $EUID = ID efetivo do usuário atual. 0 = root. Precisamos de root para
  #   instalar o K3s (que cria serviços systemd) e aplicar o cert-manager.
  echo "Rode este script com sudo: sudo $0" >&2
  exit 1
fi

# Detecta o usuário "real" que chamou o sudo, para configurar o kubeconfig e
# o runner na pasta HOME DELE (não na pasta /root) — evita que só o root
# consiga usar o kubectl/runner depois.
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME=$(getent passwd "${TARGET_USER}" | cut -d: -f6)
if [[ -z "${TARGET_HOME}" ]]; then
  log_aviso "Não consegui detectar o HOME de '${TARGET_USER}', usando /root."
  TARGET_HOME="/root"
fi
log_info "Usuário alvo para kubeconfig/runner: ${TARGET_USER} (HOME=${TARGET_HOME})"

# Garante que temos as ferramentas básicas usadas neste script.
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  log_info "Instalando dependências (curl, jq)..."
  apt-get update -qq
  apt-get install -y -qq curl jq >/dev/null
fi

# ==============================================================================
# PASSO 1 — Instalar o K3s
# ==============================================================================
if command -v k3s >/dev/null 2>&1; then
  log_ok "K3s já está instalado — pulando instalação."
else
  log_info "Instalando o K3s (isso já inclui Traefik e o local-path-provisioner)..."
  curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
  log_ok "K3s instalado."
fi

log_info "Aguardando o nó do K3s ficar em estado 'Ready'..."
for i in $(seq 1 30); do
  if k3s kubectl get nodes 2>/dev/null | grep -q " Ready "; then
    log_ok "Nó do K3s está Ready."
    break
  fi
  sleep 2
  if [[ "${i}" -eq 30 ]]; then
    echo "O nó do K3s não ficou Ready a tempo. Verifique com: sudo k3s kubectl get nodes" >&2
    exit 1
  fi
done

# ==============================================================================
# PASSO 2 — Configurar o kubectl para o usuário comum (não-root)
# ==============================================================================
KUBE_DIR="${TARGET_HOME}/.kube"
KUBE_CONFIG="${KUBE_DIR}/config"

mkdir -p "${KUBE_DIR}"
cp /etc/rancher/k3s/k3s.yaml "${KUBE_CONFIG}"
chown -R "${TARGET_USER}":"${TARGET_USER}" "${KUBE_DIR}"
chmod 600 "${KUBE_CONFIG}"
log_ok "kubeconfig copiado para ${KUBE_CONFIG} (dono: ${TARGET_USER})."

# Usamos este kubeconfig para todos os `kubectl` seguintes neste script,
# rodando como o usuário alvo (evita misturar permissões de root/usuário).
KUBECTL_CMD=(sudo -u "${TARGET_USER}" env KUBECONFIG="${KUBE_CONFIG}" kubectl)

# ==============================================================================
# PASSO 3 — Instalar o cert-manager
# ==============================================================================
if "${KUBECTL_CMD[@]}" get namespace cert-manager >/dev/null 2>&1; then
  log_ok "cert-manager já está instalado — pulando instalação."
else
  log_info "Instalando o cert-manager (emissão automática de HTTPS)..."
  "${KUBECTL_CMD[@]}" apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  log_info "Aguardando os Pods do cert-manager ficarem prontos (até 2 minutos)..."
  "${KUBECTL_CMD[@]}" wait --for=condition=Available --timeout=120s \
    -n cert-manager deployment --all
  log_ok "cert-manager instalado e pronto."
fi

# ==============================================================================
# PASSO 4 — Registrar e iniciar o Self-Hosted Runner do GitHub Actions
# ==============================================================================
if [[ -f "${RUNNER_DIR}/.runner" ]]; then
  log_ok "Runner já está configurado em ${RUNNER_DIR} — pulando registro."
elif [[ -z "${GH_PAT}" ]]; then
  log_aviso "Variável GH_PAT não definida — pulando registro automático do runner."
  log_aviso "Registre manualmente (ver README.md, seção 4.4) ou rode de novo com:"
  log_aviso "  sudo GH_PAT=\"seu_token\" $0"
else
  log_info "Buscando a versão mais recente do GitHub Actions Runner..."

  ARCH=$(uname -m)
  case "${ARCH}" in
    x86_64)  RUNNER_ARCH="x64" ;;
    aarch64) RUNNER_ARCH="arm64" ;;
    *) echo "Arquitetura não suportada: ${ARCH}" >&2; exit 1 ;;
  esac
  # ↑ Detecta automaticamente se a VM é x86_64 (mais comum em Proxmox) ou
  #   ARM64, e baixa o pacote correto do runner para cada caso.

  RELEASE_JSON=$(curl -sfL https://api.github.com/repos/actions/runner/releases/latest)
  RUNNER_VERSION=$(echo "${RELEASE_JSON}" | jq -r '.tag_name' | sed 's/^v//')
  DOWNLOAD_URL=$(echo "${RELEASE_JSON}" | jq -r \
    ".assets[] | select(.name == \"actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz\") | .browser_download_url")

  if [[ -z "${DOWNLOAD_URL}" || "${DOWNLOAD_URL}" == "null" ]]; then
    echo "Não consegui encontrar o pacote do runner para linux-${RUNNER_ARCH}." >&2
    exit 1
  fi

  log_info "Versão encontrada: v${RUNNER_VERSION} (linux-${RUNNER_ARCH})"
  log_info "Solicitando token de registro temporário à API do GitHub..."

  REG_TOKEN=$(curl -sfL -X POST \
    -H "Authorization: token ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/actions/runners/registration-token" \
    | jq -r '.token')
  # ↑ Este é o mesmo token que você normalmente copiaria manualmente da tela
  #   "New self-hosted runner" no GitHub — aqui pedimos ele via API, usando
  #   o GH_PAT como credencial, sem precisar abrir o navegador.

  if [[ -z "${REG_TOKEN}" || "${REG_TOKEN}" == "null" ]]; then
    echo "Falha ao obter o token de registro. Verifique se o GH_PAT tem" >&2
    echo "permissão 'Administration: Read and write' no repositório ${GH_OWNER}/${GH_REPO}." >&2
    exit 1
  fi

  log_info "Baixando e configurando o runner em ${RUNNER_DIR}..."
  sudo -u "${TARGET_USER}" -H bash -c "
    set -euo pipefail
    mkdir -p '${RUNNER_DIR}'
    cd '${RUNNER_DIR}'
    curl -o actions-runner.tar.gz -sfL '${DOWNLOAD_URL}'
    tar xzf actions-runner.tar.gz
    rm actions-runner.tar.gz
    ./config.sh --unattended --replace \
      --url 'https://github.com/${GH_OWNER}/${GH_REPO}' \
      --token '${REG_TOKEN}' \
      --name '${RUNNER_NAME}' \
      --labels 'self-hosted,k3s,rondonopolis' \
      --work '_work'
  "
  # ↑ `--unattended`: não faz perguntas interativas (necessário em script).
  #   `--replace`: se já existir um runner registrado com o mesmo nome
  #   (ex.: reinstalação da VM), substitui em vez de dar erro de duplicidade.
  #   Rodado como TARGET_USER (não root) — é a prática recomendada pelo
  #   próprio GitHub, e mantém o runner com o mesmo kubeconfig configurado
  #   no passo 2.

  log_info "Instalando o runner como serviço systemd (inicia sozinho com a VM)..."
  cd "${RUNNER_DIR}"
  ./svc.sh install "${TARGET_USER}"
  ./svc.sh start
  log_ok "Runner registrado, instalado como serviço e iniciado."
fi

# ==============================================================================
# RESUMO FINAL
# ==============================================================================
echo
log_ok "Bootstrap de infraestrutura concluído."
echo
echo "O que já está pronto nesta VM:"
echo "  ✔ K3s rodando (Traefik + local-path-provisioner inclusos)."
echo "  ✔ cert-manager instalado."
echo "  ✔ kubectl configurado para o usuário '${TARGET_USER}'."
if [[ -f "${RUNNER_DIR}/.runner" ]]; then
  echo "  ✔ Self-Hosted Runner '${RUNNER_NAME}' registrado e ativo."
else
  echo "  ✘ Self-Hosted Runner NÃO registrado (rode de novo com GH_PAT definido,"
  echo "    ou registre manualmente — ver README.md seção 4.4)."
fi
echo
echo "O que ainda depende de você, fora desta VM:"
echo "  1. Editar k3s-cluster/secrets.yaml (trocar senhas fictícias) e"
echo "     k3s-cluster/cert-manager-issuer.yaml (trocar o e-mail), no seu"
echo "     computador, e dar 'git push origin main' para a pipeline aplicar."
echo "  2. Configurar os registros DNS tipo A:"
echo "       sso.rondonopolis.mt.gov.br    -> IP público desta VM"
echo "       cofre.rondonopolis.mt.gov.br  -> IP público desta VM"
echo "  3. Se esta VM estiver atrás de NAT (Proxmox/roteador), liberar o"
echo "     port-forward das portas 80 e 443 para o IP interno dela."
