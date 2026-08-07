# Configuração de referência para o Nginx da borda

Esta pasta **não é aplicada no cluster K3s** (o Nginx da borda não roda
dentro do Kubernetes — ele é o servidor isolado já existente na rede da
prefeitura). Os dois arquivos aqui são apenas **referência**, prontos para
você copiar/adaptar dentro da configuração que já existe nesse servidor
(ex.: dentro de `/etc/nginx/sites-available/`, `/etc/nginx/conf.d/`, ou onde
quer que o padrão de vhosts de vocês já esteja organizado).

| Arquivo | Domínio | Aponta para (dentro do K3s) |
|---|---|---|
| `sso.rondonopolis.mt.gov.br.conf` | Keycloak | Traefik → Service `keycloak` |
| `cofre.rondonopolis.mt.gov.br.conf` | Vaultwarden | Traefik → Service `vaultwarden` |

## O que você PRECISA ajustar antes de usar

Em **ambos** os arquivos, procure por `SUBSTITUA_PELO_IP_DA_VM_K3S` e troque
pelo IP interno real da VM onde o K3s está rodando (ex.: `10.10.0.20`). Os
dois domínios apontam para a **mesma VM**, na **mesma porta 80** — é o
Traefik, dentro do cluster, quem decide para qual aplicação (Keycloak ou
Vaultwarden) encaminhar, com base no `Host` que o Nginx repassa.

Os caminhos de certificado (`ssl_certificate` / `ssl_certificate_key`) estão
com placeholders — ajuste para onde o seu Nginx já guarda os certificados
reais desses domínios (Let's Encrypt/certbot, certificado da prefeitura,
etc.). Isso já é gerenciado por vocês fora deste repositório.

## Por que os cabeçalhos `X-Forwarded-*` importam aqui

O Keycloak e o Vaultwarden, dentro do K3s, só recebem tráfego HTTP puro do
Traefik — eles não "veem" HTTPS diretamente. Para saberem que o usuário
final acessou via HTTPS (essencial para gerar URLs corretas e cookies
seguros), o Nginx precisa enviar os cabeçalhos `X-Forwarded-Proto`,
`X-Forwarded-Host` e `X-Forwarded-For` — já incluídos nos dois arquivos
abaixo. Do lado do cluster, o arquivo
`k3s-cluster/traefik-trusted-headers.yaml` precisa estar configurado com o
IP deste Nginx para que o Traefik CONFIE nesses cabeçalhos em vez de
sobrescrevê-los — os dois lados (Nginx + Traefik) têm que estar alinhados.

## Testando depois de configurar

```bash
# Do próprio servidor Nginx, teste se a VM do K3s responde na porta 80:
curl -H "Host: sso.rondonopolis.mt.gov.br" http://SUBSTITUA_PELO_IP_DA_VM_K3S/

# Depois de recarregar o Nginx (nginx -t && systemctl reload nginx),
# teste de fora da rede:
curl -I https://sso.rondonopolis.mt.gov.br
```
