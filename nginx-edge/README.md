# Configuração de referência para o Nginx da borda (aaPanel/BT Panel)

Esta pasta **não é aplicada no cluster K3s** — o Nginx da borda é o
servidor isolado já existente na rede da prefeitura (aaPanel/BT Panel, IP
`192.168.0.218`), gerenciado fora deste repositório. Os arquivos aqui são
uma **cópia próxima do que está de fato no servidor**, com apenas os
trechos necessários para apontar para o novo K3s marcados como alterados —
não configs genéricas.

| Arquivo | Domínio | Situação |
|---|---|---|
| `sso.rondonopolis.mt.gov.br.conf` | Keycloak | **Já existe** no servidor — hoje aponta para o Keycloak antigo (porta 18443); o diff necessário está marcado com `# ALTERADO:` / `# NOVO:` |
| `cofre.rondonopolis.mt.gov.br.conf` | Vaultwarden | **Site novo** — precisa ser criado no painel primeiro (ver instruções no topo do arquivo) |

## Rede desta instalação

| Servidor | IP interno |
|---|---|
| VM do K3s (mesma VM que já hospeda o Keycloak antigo, porta 18443) | `192.168.0.225` |
| Nginx da borda / aaPanel (este servidor) | `192.168.0.218` |

## Como aplicar

**`sso.rondonopolis.mt.gov.br`** (site já existe): no painel, vá em
Website → sso.rondonopolis.mt.gov.br → **Config Files** (ou edite o
arquivo diretamente em
`/www/server/panel/vhost/nginx/sso.rondonopolis.mt.gov.br.conf`), localize
o bloco `#PROXY-CONF-START ... #PROXY-CONF-END` e aplique as duas mudanças
marcadas no arquivo local: trocar a porta do `proxy_pass` de `18443` para
`80`, e adicionar as duas linhas de `X-Forwarded-Proto`/`X-Forwarded-Host`.
Depois: `nginx -t && systemctl reload nginx` (ou o botão "Reload" do
painel).

**`cofre.rondonopolis.mt.gov.br`** (site novo): siga as instruções no
cabeçalho do arquivo `cofre.rondonopolis.mt.gov.br.conf` — criar o site
pelo painel, emitir o certificado Let's Encrypt pela aba SSL, e então
aplicar o bloco de proxy reverso (o arquivo aqui serve de conferência).

## ⚠️ Sobre editar direto vs. usar a interface gráfica do painel

Se você usar a ferramenta gráfica **"Proxy Reverso"** do aaPanel nas
configurações de um desses sites depois de aplicar estes ajustes, ela
**regenera o bloco `#PROXY-CONF-START ... #PROXY-CONF-END` sozinha** —
os cabeçalhos extras (`X-Forwarded-Proto`, `X-Forwarded-Host`) seriam
perdidos nesse caso. Se precisar usar a interface gráfica de novo no
futuro, reaplique essas duas linhas manualmente depois.

## Por que os cabeçalhos `X-Forwarded-*` importam aqui

O Keycloak e o Vaultwarden, dentro do K3s, só recebem tráfego HTTP puro do
Traefik — eles não "veem" HTTPS diretamente. `X-Forwarded-Proto: https`
avisa que a conexão original do usuário foi HTTPS. Do lado do cluster, o
arquivo `k3s-cluster/traefik-trusted-headers.yaml` já está configurado com
o IP deste Nginx (`192.168.0.218`) para que o Traefik CONFIE nesses
cabeçalhos em vez de sobrescrevê-los.

## Sobre o cutover do Keycloak antigo para o novo

O Keycloak antigo (bare-metal/Docker, porta 18443) e o novo (K3s, porta 80)
podem rodar ao mesmo tempo na mesma VM sem conflito de porta — útil
durante os testes. Mas os dois juntos disputam RAM na VM de 8GB. Depois de
validar que o Keycloak novo está funcionando bem (login, redirect,
sessões), pare os containers do Keycloak antigo antes de considerar a
migração definitiva.

## Testando depois de configurar

```bash
# Do próprio servidor Nginx, teste se a VM do K3s responde na porta 80:
curl -H "Host: sso.rondonopolis.mt.gov.br" http://192.168.0.225/

# Depois de recarregar o Nginx (nginx -t && systemctl reload nginx),
# teste de fora da rede:
curl -I https://sso.rondonopolis.mt.gov.br
```
