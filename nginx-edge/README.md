# Nginx da borda (aaPanel/BT Panel) — ZERO alterações necessárias

Esta pasta **não é aplicada no cluster K3s**. O Nginx da borda (IP
`192.168.0.218`) é um servidor separado, já existente e já configurado —
os arquivos aqui são cópias EXATAS, sem modificação, dos vhosts reais que
já estão nele.

## A decisão de arquitetura

O Keycloak e o Vaultwarden que rodavam nesta VM (`192.168.0.225`) antes do
K3s (bare-metal/Docker, ambiente de teste/POC, sem dado real de produção)
usavam portas específicas:

| Domínio | Serviço | Porta na VM |
|---|---|---|
| `sso.rondonopolis.mt.gov.br` | Keycloak | `18443` |
| `cofre.rondonopolis.mt.gov.br` | Vaultwarden | `8081` |

Em vez de mudar essa arquitetura (ex.: um Ingress único na porta 80,
roteando por domínio via Traefik — o que exigiria editar os dois vhosts do
Nginx), o K3s foi configurado para **expor cada serviço exatamente nas
mesmas portas de antes**, via `Service` do tipo `LoadBalancer`:

- `k3s-cluster/keycloak.yaml` → Service `keycloak-external`, porta `18443`
- `k3s-cluster/vaultwarden.yaml` → Service `vaultwarden-external`, porta `8081`

O K3s já vem com um "ServiceLB" embutido (também chamado *klipper-lb*) que
atende `type: LoadBalancer` sem precisar instalar nada extra (MetalLB,
etc.) — ele simplesmente faz a VM escutar a porta pedida e encaminhar para
o Pod certo. Do ponto de vista do Nginx, **nada mudou**: ele continua
mandando tráfego para `192.168.0.225:18443` e `192.168.0.225:8081`, só que
agora quem responde é o K3s, não mais o Docker antigo.

## Por que isso é melhor que mudar o Nginx

- **Zero risco de errar a config de um servidor gerenciado à parte** — o
  Nginx já está testado e funcionando, com certificados válidos já
  emitidos pelo painel.
- **Zero dependência de coordenação** — a troca de porta de origem (Docker
  antigo → K3s novo) acontece inteiramente do lado do K3s; ninguém
  precisa mexer no aaPanel.
- **Rollback trivial** — se algo der errado no K3s, é só o K3s parar de
  responder nessas portas; o Nginx nem percebe a diferença (dá 502, como
  daria se qualquer backend caísse).

## `externalTrafficPolicy: Local` — por que existe

Os dois Services LoadBalancer usam `externalTrafficPolicy: Local`, para
que o Keycloak/Vaultwarden enxerguem o IP REAL de quem conecta (o Nginx,
`192.168.0.218`) em vez de um IP interno do cluster (o Kubernetes faz NAT
por padrão nessas conexões, a menos que esta opção esteja ativa). Isso é o
que faz `KC_PROXY_TRUSTED_ADDRESSES` (em `keycloak.yaml`) funcionar
corretamente. Só é seguro usar "Local" porque o cluster é single-node
(toda a rede fica no mesmo lugar) — não use isso sem entender as
implicações em um cluster com múltiplos nós.

## Testando

```bash
# Do próprio servidor Nginx (192.168.0.218), confirme que a VM do K3s
# responde nas portas certas:
curl -I http://192.168.0.225:18443/   # deve responder (Keycloak)
curl -I http://192.168.0.225:8081/    # deve responder (Vaultwarden)

# De fora da rede, teste os domínios públicos normalmente:
curl -I https://sso.rondonopolis.mt.gov.br
curl -I https://cofre.rondonopolis.mt.gov.br
```

Se algum desses `curl` direto na porta der "Connection refused", o
problema está no lado do K3s (Service/Pod não está no ar — veja
`kubectl get svc,pods -n authentication`). Se a porta responde mas o
domínio via HTTPS não, o problema está na config do Nginx/certificado —
mas como não mudamos nada nele, isso indicaria uma causa não relacionada a
esta migração.
