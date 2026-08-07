# Configuração de referência para o Nginx da borda (aaPanel/BT Panel)

Esta pasta **não é aplicada no cluster K3s** — o Nginx da borda é o
servidor isolado já existente na rede da prefeitura (aaPanel/BT Panel, IP
`192.168.0.218`), gerenciado fora deste repositório. Os arquivos aqui são
uma **cópia próxima do que está de fato no servidor**, com apenas os
trechos necessários para apontar para o novo K3s marcados como alterados —
não configs genéricas.

| Arquivo | Domínio | Situação | Alvo antigo (bare-metal, hoje desligado) | Alvo novo (K3s) |
|---|---|---|---|---|
| `sso.rondonopolis.mt.gov.br.conf` | Keycloak | Vhost existe, backend desligado | `192.168.0.225:18443` | `192.168.0.225:80` |
| `cofre.rondonopolis.mt.gov.br.conf` | Vaultwarden | Vhost existe, backend desligado | `192.168.0.225:8081` | `192.168.0.225:80` |

Os dois vhosts já existem no Nginx (foram usados por um Keycloak/Vaultwarden
bare-metal de teste/POC na mesma VM `192.168.0.225`). Esse setup antigo já
foi **desligado e removido** dessa VM (sem dado real de produção — nada a
migrar), então os dois domínios estão retornando erro até o K3s subir e a
porta do `proxy_pass` ser trocada. Não é preciso criar site novo em nenhum
dos dois casos, só aplicar o diff marcado no arquivo.

## Rede desta instalação

| Servidor | IP interno |
|---|---|
| VM do K3s (mesma VM que antes hospedava o Keycloak/Vaultwarden de teste, hoje desligados) | `192.168.0.225` |
| Nginx da borda / aaPanel (este servidor) | `192.168.0.218` |

## Como aplicar

Para os dois domínios, o fluxo é o mesmo: no painel, vá em Website →
`<domínio>` → **Config Files** (ou edite direto em
`/www/server/panel/vhost/nginx/<domínio>.conf`), localize o bloco
`#PROXY-CONF-START ... #PROXY-CONF-END` e aplique as mudanças marcadas
com `# ALTERADO:`/`# NOVO:` no arquivo local correspondente. Depois:
`nginx -t && systemctl reload nginx` (ou o botão "Reload" do painel).

## ⚠️ Sobre editar direto vs. usar a interface gráfica do painel

Se você usar a ferramenta gráfica **"Proxy Reverso"** do aaPanel nas
configurações de um desses sites depois de aplicar estes ajustes, ela
**regenera o bloco `#PROXY-CONF-START ... #PROXY-CONF-END` sozinha** —
os cabeçalhos extras (`X-Forwarded-Proto`, `X-Forwarded-Host`) e o
`client_max_body_size` (no caso do cofre) seriam perdidos nesse caso. Se
precisar usar a interface gráfica de novo no futuro, reaplique esses
ajustes manualmente depois.

## Por que os cabeçalhos `X-Forwarded-*` importam aqui

O Keycloak e o Vaultwarden, dentro do K3s, só recebem tráfego HTTP puro do
Traefik — eles não "veem" HTTPS diretamente. `X-Forwarded-Proto: https`
avisa que a conexão original do usuário foi HTTPS. Do lado do cluster, o
arquivo `k3s-cluster/traefik-trusted-headers.yaml` já está configurado com
o IP deste Nginx (`192.168.0.218`) para que o Traefik CONFIE nesses
cabeçalhos em vez de sobrescrevê-los.

## Testando depois de configurar

```bash
# Do próprio servidor Nginx, teste se a VM do K3s responde na porta 80:
curl -H "Host: sso.rondonopolis.mt.gov.br" http://192.168.0.225/
curl -H "Host: cofre.rondonopolis.mt.gov.br" http://192.168.0.225/

# Depois de recarregar o Nginx (nginx -t && systemctl reload nginx),
# teste de fora da rede:
curl -I https://sso.rondonopolis.mt.gov.br
curl -I https://cofre.rondonopolis.mt.gov.br
```
