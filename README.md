# Servidor de velocidade do provedor (L1 Diag)

Instala, com um único script, o servidor de teste de velocidade que o app
**L1 Diag** usa quando o cliente está na rede do provedor. O teste fica dentro
da rede do provedor e mede o link do cliente de verdade, sem depender da
Cloudflare.

O script instala o [LibreSpeed speedtest-go](https://github.com/librespeed/speedtest-go)
com HTTPS, como serviço do systemd, testa tudo e no fim mostra o registro DNS
(BIND) que falta criar.

## Instalar pelo painel L1 Diag ISP (recomendado)

No [painel L1 Diag ISP](https://isp.l1diag.l1sistemas.com.br), em
**Adicionar servidor**, preencha o nome de exibição, o nome DNS, os IPs e a
prioridade. O painel gera um comando pronto:

```sh
curl -fsSL https://raw.githubusercontent.com/wilsonritt/l1-speed-server/main/install.sh -o install.sh && sudo bash install.sh --code xxxxx-xxxxx-xxxxx-xxxxx
```

Com o código, o script já sabe o nome, o nome DNS, o site e a prioridade. Ele
só pergunta a porta e o certificado. No fim, registra o servidor no painel:
os clientes que saem pelas redes aprovadas do provedor passam a usá-lo com
qualquer DNS, sem registro no BIND.

## Instalar sem o painel

No servidor (Debian, Ubuntu, Rocky, Alma ou similar, com systemd), como root:

```sh
curl -fsSL https://raw.githubusercontent.com/wilsonritt/l1-speed-server/main/install.sh -o install.sh
sudo bash install.sh
```

O script pergunta:

| Pergunta | Para que serve |
| --- | --- |
| Nome do servidor | Nome público com registro A/AAAA, ex.: `speed1.provedor.com.br`. O certificado HTTPS sai para ele. |
| Nome no teste | O que o cliente vê no app durante o teste, ex.: `RBT Telecom 10G`. |
| Site do provedor | Opcional. Vai junto no registro DNS. |
| Porta | Mostra as portas em uso e sugere uma livre (8443, 9443...). Recusa porta ocupada. |
| Prioridade | Com mais de um servidor, o app usa primeiro o menor número. |
| Certificado | Emitir com Let's Encrypt (renova sozinho) ou usar arquivos que você já tem. |
| Ajustes de rede | Buffers TCP e BBR, para passar de 1 Gbps. |

Depois mostra um resumo e só instala se você confirmar.

### Requisitos

- Um nome DNS público apontando para o servidor, antes de pedir o certificado.
- Para o Let's Encrypt, a porta 80 acessível da internet. Se ela já tiver um
  site, o script usa a pasta pública dele (webroot).
- A porta do teste liberada no firewall e na borda para os clientes.
- Para testes acima de 1 Gbps, placa e uplink compatíveis. O app mostra o
  limite do aparelho do cliente, então o servidor precisa ser mais rápido que ele.

## O que é instalado

| Caminho | Conteúdo |
| --- | --- |
| `/opt/l1speed/speedtest-backend` | Binário oficial do speedtest-go, com SHA-256 conferido. |
| `/etc/l1speed/settings.toml` | Configuração. Não grava resultados nem IPs. |
| `/etc/l1speed/tls/` | Cópia do certificado, legível só pelo serviço. |
| `/etc/l1speed/install.conf` | Suas respostas, reaproveitadas na próxima execução. |
| `/etc/l1speed/DNS-BIND.txt` | As instruções de DNS mostradas no fim. |
| `l1speed.service` | Serviço do systemd, com usuário próprio e sem acesso de escrita ao sistema. |
| `/etc/sysctl.d/90-l1speed.conf` | Ajustes de rede, se você aceitar. |

O firewall (ufw ou firewalld) é liberado na porta escolhida quando está ativo.
Com Let's Encrypt, um hook copia o certificado renovado e reinicia o serviço.

## DNS (sem o painel, ou como reserva)

No fim, o script imprime (e salva em `/etc/l1speed/DNS-BIND.txt`) o registro
TXT para os resolvers BIND que atendem os clientes, com dois jeitos de criar:

- **Zona local só para o nome `_speedtest.l1diag.l1sistemas.com.br`** (recomendado).
- **Uma linha na RPZ**, para quem já usa RPZ.

> **Importante:** crie a zona ou a regra só para o nome exato
> `_speedtest.l1diag.l1sistemas.com.br`. **Nunca** crie zona nem RPZ para
> `l1sistemas.com.br` inteiro (ou `*.l1sistemas.com.br`): os clientes
> perderiam o acesso aos sites e serviços da L1.

O valor do registro fica assim:

```
v=l1speed1; url=https://speed1.provedor.com.br:8443/; nome=RBT Telecom 10G; prio=10; site=https://provedor.com.br
```

Antes do DNS, já dá para testar no app: **Velocidade > Servidor > Servidor do
provedor**, digitando `speed1.provedor.com.br:8443`.

## Reconfigurar, atualizar e remover

```sh
sudo bash install.sh              # roda de novo: reaproveita as respostas e baixa a versão mais nova
sudo bash install.sh --uninstall  # remove serviço, binário e configuração
```

O certificado do Let's Encrypt fica em `/etc/letsencrypt` ao remover.

## Instalar sem perguntas

Com `--yes`, o script usa as variáveis abaixo (ou as respostas anteriores) e
não pergunta nada:

```sh
sudo L1S_HOST=speed1.provedor.com.br L1S_NAME="RBT Telecom 10G" L1S_PORT=8443 \
     L1S_CERT=letsencrypt L1S_EMAIL=noc@provedor.com.br bash install.sh --yes
```

| Variável | Valor |
| --- | --- |
| `L1S_HOST` | Nome público do servidor. |
| `L1S_NAME` | Nome no app. |
| `L1S_SITE` | Site do provedor (opcional). |
| `L1S_PORT` | Porta HTTPS. |
| `L1S_PRIO` | Prioridade no DNS (padrão 10). |
| `L1S_TUNE` | `s` ou `n` para os ajustes de rede. |
| `L1S_CERT` | `letsencrypt` ou `files`. |
| `L1S_EMAIL` | E-mail do Let's Encrypt. |
| `L1S_WEBROOT` | Pasta pública, se a porta 80 já tiver um site. |
| `L1S_CERT_FILE`, `L1S_KEY_FILE` | Certificado (fullchain) e chave, com `L1S_CERT=files`. |
| `L1S_BACKEND_VERSION` | Versão do speedtest-go, ex.: `1.1.5`. Padrão: a mais nova. |
| `L1S_CODE` | Código gerado no painel (o mesmo que `--code`). |
| `L1S_ISP_URL` | Endereço do painel. Padrão: `https://isp.l1diag.l1sistemas.com.br`. |
| `L1S_BACKEND_FILE` | Pacote `.tar.gz` local do speedtest-go, para servidor sem acesso ao GitHub. |

## Problemas comuns

- **O app não acha o servidor no modo Automático:** confira com
  `dig @IP_DO_RESOLVER TXT _speedtest.l1diag.l1sistemas.com.br +short` e
  se o cliente usa esse resolver (com DNS 1.1.1.1 ou 8.8.8.8 no aparelho, o
  app não vê o registro e usa a Cloudflare).
- **"Certificado não aceito":** o app exige certificado válido para o nome,
  com a cadeia completa (fullchain). Certificado autoassinado não funciona.
- **Ver o log:** `journalctl -u l1speed -f`.

## Licença

MIT. O LibreSpeed speedtest-go é baixado do repositório oficial e segue a
licença dele (LGPL-3.0).
