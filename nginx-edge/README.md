# Configuração de referência para o Nginx da borda (aaPanel/BT Panel)

Esta pasta **não é aplicada no cluster K3s** — o Nginx da borda é o
servidor isolado já existente na rede da prefeitura (aaPanel/BT Panel, IP
`192.168.0.218`), gerenciado fora deste repositório. Os arquivos aqui são
uma **cópia próxima do que está de fato no servidor**, com apenas os
trechos necessários para apontar para o novo K3s marcados como alterados —
não configs genéricas.

| Arquivo | Domínio | Situação | Alvo atual (bare-metal) | Alvo novo (K3s) |
|---|---|---|---|---|
| `sso.rondonopolis.mt.gov.br.conf` | Keycloak | **Já existe e já roda** | `192.168.0.225:18443` | `192.168.0.225:80` |
| `cofre.rondonopolis.mt.gov.br.conf` | Vaultwarden | **Já existe e já roda** | `192.168.0.225:8081` | `192.168.0.225:80` |

Os dois sites já existem hoje, ambos apontando para serviços bare-metal na
mesma VM que vai receber o K3s (`192.168.0.225`) — a migração é a mesma
para os dois: trocar a porta do `proxy_pass` e adicionar os cabeçalhos que
faltam. Não é preciso criar site novo em nenhum dos dois casos.

## Rede desta instalação

| Servidor | IP interno |
|---|---|
| VM do K3s (mesma VM que já hospeda o Keycloak em `:18443` e o Vaultwarden em `:8081`) | `192.168.0.225` |
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

## ⚠️ Sobre o cutover — dados existentes, não só configuração

Os serviços atuais (Keycloak em `:18443`, Vaultwarden em `:8081`) e os
novos no K3s podem rodar ao mesmo tempo, em portas diferentes, sem
conflito — útil para testar antes de trocar de vez. Mas atenção:

- **Keycloak**: o banco Postgres do K3s começa vazio — sem os realms,
  usuários e clients já configurados no Keycloak atual. Um plano de
  migração de dados (dump/restore do Postgres atual para o do K3s, ou
  export/import de realm) é necessário antes do cutover definitivo.
- **Vaultwarden**: o PVC do K3s também começa vazio — sem os cofres,
  senhas e anexos já salvos no Vaultwarden atual (banco SQLite + pasta de
  anexos). Migrar esses dados é obrigatório antes de apontar este domínio
  definitivamente para o K3s, ou os usuários "perderiam" o acesso aos
  cofres que já têm hoje (os dados continuam existindo no servidor antigo,
  só não estariam disponíveis pelo Vaultwarden novo).

**Recomendação:** só troque a porta do `proxy_pass` em definitivo depois
de ter um plano de migração de dados para os dois serviços — até lá, teste
o K3s acessando via IP/porta interna diretamente (`curl -H "Host: ..." ...`),
sem apontar o domínio de produção para ele.

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
