# Segurança — `keycloak-k3s`

Este arquivo resume a auditoria de segurança de ago/2026, o que foi corrigido
diretamente neste repositório, e o que exige uma ação manual (acesso à VM,
ao cluster ou ao Active Directory de produção — fora do alcance de qualquer
ferramenta que só edita arquivos neste Git).

Contexto: este repositório é **público** no GitHub (decisão consciente,
revisitada nesta auditoria — ver seção "Visibilidade do repositório"
abaixo) e descreve a stack de identidade real da Prefeitura Municipal de
Rondonópolis-MT (Keycloak + Active Directory + Vaultwarden).

## Corrigido nesta auditoria (já neste commit)

| Item | O quê mudou | Arquivo(s) |
|---|---|---|
| DN da conta admin do AD versionado | `AD_BIND_DN` (usuário + estrutura completa de OUs de uma conta ADMINISTRATIVA do domínio) saiu de `secrets.yaml` (texto claro, versionado, público) e passou a viver no mesmo Secret manual e não-versionado que já guardava a senha (`ad-bind-credentials`) | `secrets.yaml`, `ldap-federation-job.yaml`, `README.md` |
| TLSv1.1 habilitado na borda | Removido dos dois vhosts de referência (Keycloak e Vaultwarden) — protocolo obsoleto, depreciado por PCI-DSS desde 2018 | `nginx-edge/*.conf` |
| HSTS sem `includeSubDomains` | Adicionado nos dois vhosts | `nginx-edge/*.conf` |
| Runner do deploy com `cluster-admin` total | RBAC escopado (ServiceAccount + Role + ClusterRole mínima) **desenhado e pronto para ativar** — ainda não ligado ao runner (ver runbook abaixo) | `k3s-cluster/rbac-deployer.yaml` |

## Pendente — exige ação manual sua (não pode ser feito só editando o Git)

### 1. Rotacionar a senha da conta `<conta-servico-ad>` no Active Directory
O nome de usuário e o DN completo desta conta ficaram versionados em texto
claro num repositório público por vários commits — o histórico do Git não
esquece, mesmo já tendo sido removido do arquivo atual. Trate a senha atual
como potencialmente exposta.

```
# Direto no Domain Controller / ferramenta de administração do AD da prefeitura
# (fora do alcance deste repositório — sem acesso ao AD daqui)
```

Depois de trocar, atualize também o Secret `ad-bind-credentials` no cluster
(ver comando no cabeçalho de `k3s-cluster/ldap-federation-job.yaml`).

A médio prazo: trocar `<conta-servico-ad>` (conta administrativa do domínio) por uma
conta de serviço dedicada, só leitura, sem restrição de horário de logon —
já é uma pendência de prioridade elevada documentada na seção 9 do README,
anterior a esta auditoria.

### 2. Ativar o RBAC escopado do runner (`rbac-deployer.yaml`)
O manifest já existe e está pronto, mas trocar o kubeconfig que o runner
self-hosted usa de fato é uma operação na VM de produção. Passo a passo
completo, incluindo teste isolado antes de trocar em definitivo, no rodapé
de `k3s-cluster/rbac-deployer.yaml` ("COMO ATIVAR"). Atenção especial à
ressalva sobre o step do Portainer — ele precisa de uma credencial com
permissão de `cluster-admin` por natureza (o próprio manifesto do Portainer
exige isso), então não some por completo mesmo depois desta troca.

### 3. Migrar `secrets.yaml` para segredos criptografados
Hoje os valores em `secrets.yaml` são placeholders fictícios claramente
marcados — mas o padrão (`stringData` em texto claro) significa que o
primeiro valor real que alguém colar ali, ao dar `git push`, fica exposto
no histórico do Git para sempre (mesmo revertendo depois). Recomendação já
documentada no cabeçalho do próprio arquivo, não implementada ainda:

- **Bitnami Sealed Secrets** — criptografa cada Secret com a chave pública
  do cluster; só o controller dentro do cluster consegue decifrar. Só o
  `SealedSecret` (cifrado) é versionado.
- **Mozilla SOPS + age/GPG** — criptografa o YAML inteiro antes do commit.
- **External Secrets Operator** — busca os valores de um cofre externo
  (Vault, AWS/Azure Secrets Manager) em runtime, sem versionar segredo
  nenhum.

Qualquer uma das três é uma melhoria real sobre o estado atual; a escolha
depende de que infraestrutura de apoio (Vault, chave GPG, etc.) a prefeitura
já tem ou está disposta a manter.

## Visibilidade do repositório

Decisão registrada nesta auditoria: **manter público por enquanto**. Dado
isso, o item acima (DN do AD) foi tratado como se o repositório fosse
permanentemente público — ou seja, a correção não depende de reverter essa
decisão no futuro. Se a decisão mudar, revisar de novo:

- Todos os IPs internos (`192.168.0.x`) e a topologia da rede (portas,
  hostnames internos) permanecem versionados — são endereços privados
  (RFC 1918), não roteáveis pela internet, e vários deles são valores
  *funcionais* usados de verdade por `NetworkPolicy`/`KC_PROXY_TRUSTED_ADDRESSES`
  (trocar por placeholder quebraria esses manifestos ao reaplicar). O custo
  de mascará-los supera o ganho de segurança nesse caso específico — só têm
  utilidade real para alguém que já tem acesso à rede interna da prefeitura,
  cenário em que descobri-los por outros meios (ARP, DNS interno) é trivial.
- Os vhosts em `nginx-edge/*.conf` continuam sendo cópias de referência
  fiéis do Nginx real — inclusive o IP do próprio Nginx de borda. Mesma
  lógica acima.

## Já verificado e correto (nenhuma ação necessária)

- Nenhuma senha real (só placeholders claramente marcados) em `secrets.yaml`.
- Senha da conta de bind do AD nunca versionada, desde antes desta auditoria
  (só o DN estava, corrigido acima).
- `deploy.yml` roda em runner self-hosted (nenhuma porta de entrada exposta
  para a internet) e usa `permissions: contents: read` (sem escrita no
  repositório).
- `.gitattributes` força LF em `.sh`/`.yaml`/`.yml`, evitando quebra de
  scripts entre SOs.
