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
| Nome no teste | O que o cliente vê no app durante o teste, ex.: `Provedor Exemplo 10G`. |
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
| `/opt/l1speed/www/index.html` | Página de quem abre o endereço do servidor no navegador: com a cara do L1 Diag e um botão que faz o teste completo pelo painel, no lugar da página padrão do LibreSpeed. |
| `/opt/l1speed/www/l1speed.json` | Versão e resultado da última atualização, lido pelo painel L1 Diag ISP em `https://servidor:porta/l1speed.json`. |
| `/usr/local/sbin/l1speed` | Cópia do instalador, usada pela atualização automática. |
| `l1speed-update.timer` | Atualização automática diária (veja abaixo). |
| `/var/lib/l1speed/` | Cópia de segurança da versão anterior durante a atualização. |

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
v=l1speed1; url=https://speed1.provedor.com.br:8443/; nome=Provedor Exemplo 10G; prio=10; site=https://provedor.com.br
```

Antes do DNS, já dá para testar no app: **Velocidade > Servidor > Servidor do
provedor**, digitando `speed1.provedor.com.br:8443`.

## Atualização automática

O servidor se atualiza sozinho: o provedor não precisa acompanhar as versões.
Todo dia, num horário sorteado entre 3h e 6h, o timer `l1speed-update`:

1. Confere se saiu um instalador novo (a última
   [Release](https://github.com/wilsonritt/l1-speed-server/releases) deste
   repositório) e, se saiu, passa a usá-lo.
2. Confere se saiu um speedtest-go novo e baixa com o SHA-256 conferido.
3. Só reinicia o serviço se algo mudou de verdade. Depois de reiniciar, faz o
   mesmo teste da instalação (latência, download e upload).
4. Se o serviço não subir ou não passar no teste, volta sozinho para a versão
   anterior e não tenta de novo aquela versão. O erro fica no log.

```sh
systemctl list-timers l1speed-update    # quando é a próxima
journalctl -u l1speed-update            # o que aconteceu nas últimas
sudo l1speed --update                   # atualizar agora
sudo l1speed --no-auto-update           # desligar (--auto-update religa)
```

Servidor instalado antes do instalador 1.2.0 não tem a atualização
automática. Para ligar, rode uma vez (não pergunta nada nem muda as
respostas):

```sh
curl -fsSL https://raw.githubusercontent.com/wilsonritt/l1-speed-server/main/install.sh -o install.sh && sudo bash install.sh --update
```

Para publicar uma versão: suba `VERSION_SCRIPT` no `install.sh` e crie a tag
`vX.Y.Z` igual. O workflow `release` cria a Release, e os servidores pegam na
madrugada seguinte. O que está só no `main` vale para instalações novas, mas
não chega sozinho aos servidores já instalados.

## Reconfigurar e remover

```sh
sudo bash install.sh              # roda de novo: reaproveita as respostas e baixa a versão mais nova
sudo bash install.sh --uninstall  # remove serviço, binário, timer e configuração
```

O certificado do Let's Encrypt fica em `/etc/letsencrypt` ao remover.

## Instalar sem perguntas

Com `--yes`, o script usa as variáveis abaixo (ou as respostas anteriores) e
não pergunta nada:

```sh
sudo L1S_HOST=speed1.provedor.com.br L1S_NAME="Provedor Exemplo 10G" L1S_PORT=8443 \
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
| `L1S_AUTO_UPDATE` | `s` (padrão) ou `n` para a atualização automática. |

## Problemas comuns

- **O app não acha o servidor no modo Automático:** confira com
  `dig @IP_DO_RESOLVER TXT _speedtest.l1diag.l1sistemas.com.br +short` e
  se o cliente usa esse resolver (com DNS 1.1.1.1 ou 8.8.8.8 no aparelho, o
  app não vê o registro e usa a Cloudflare).
- **"Certificado não aceito":** o app exige certificado válido para o nome,
  com a cadeia completa (fullchain). Certificado autoassinado não funciona.
- **Ver o log:** `journalctl -u l1speed -f`.

## Licença

MIT. O LibreSpeed speedtest-go é baixado do repositório oficial, sem
modificação, e segue a licença dele (LGPL-3.0). A página do servidor é do
L1 Diag (não usa a interface do LibreSpeed) e dá o crédito ao speedtest-go.
