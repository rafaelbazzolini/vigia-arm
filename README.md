# Vigia ARM

Cliente de vídeo independente para **macOS 14+ e Apple Silicon**, escrito em Swift/SwiftUI. Nome provisório do projeto. Não é uma versão do SIM Play, não incorpora seus assemblies, recursos, SDKs ou ícones e não possui vínculo com a Intelbras/Dahua.

## Funções

- Cadastro de câmeras e gravadores por endereço, usuário e senha.
- Descoberta ONVIF na rede local e consulta dos perfis Media1.
- Cadastro manual de URLs RTSP, com usuário e senha em campos separados.
- Mosaicos de 1, 4, 9 ou 16 canais, conexão sob demanda e reconexão manual.
- Modos Econômico, Equilibrado e Detalhado para a prévia; vídeo H.264, HEVC e MPEG-4 conforme a compilação do FFmpeg.
- Captura de imagem PNG; gravação do stream original em MKV sem reencodificação.
- Reprodução de arquivos locais e monitoramento de áudio de um canal.
- Consulta de fontes de gravação, reprodução a partir de data/hora e exportação de período por ONVIF Profile G.
- Comandos PTZ curtos de direção/zoom no menu de contexto do painel, quando o perfil oferece PTZ.
- Exportação de configuração JSON sem senhas.
- Backup completo criptografado com AES-256-GCM, senha de backup e PBKDF2-HMAC-SHA256 (300 mil iterações, salt aleatório).
- Prévia de importação, mesclagem ou substituição da configuração; senhas no Chaves do macOS.

**O suporte real às funções ONVIF depende do equipamento. Implementação não significa homologação universal.** Consulte `docs/VALIDATION.md` para saber exatamente o que foi testado. A primeira versão não possui Conta Intelbras, P2P do fabricante, eventos inteligentes ou conversor de backup proprietário do SIM Play. Gravações remotas exigem os serviços Recording/Replay (Profile G); muitos gravadores não os oferecem, mesmo quando têm ONVIF para vídeo ao vivo.

## Abrir o app

Abra `VigiaARM.app`. Adicione um equipamento, informe o endereço e as credenciais e clique em **Buscar canais ONVIF**, ou adicione uma URL RTSP manual. Salve, selecione um painel e abra o canal na lista lateral. A descoberta não envia senhas; as conexões usam as credenciais cadastradas.

Os perfis ONVIF podem representar substreams diferentes do mesmo canal. Os caminhos RTSP de exemplo são sugestões e não garantem compatibilidade com um modelo.

Na aba **Backups**, exporte JSON sem senhas ou crie um backup completo criptografado. A senha do backup não é salva nem recuperável. A importação mostra os equipamentos antes de aplicar; ela não altera os dispositivos físicos. Não importe arquivos de origem desconhecida.

A configuração fica em `~/Library/Application Support/VigiaARM/configuration.json`; as senhas ficam no Chaves, serviço `io.github.rafaelbazzolini.vigia-arm`. Um build de desenvolvimento pode indicar outra pasta de dados. Gravações e imagens são salvas somente onde você escolher. O programa não envia telemetria nem publica configurações.

## Compilar

Requer Mac Apple Silicon, Xcode/Command Line Tools, Python 3.9+ e FFmpeg compilado conforme o script do projeto. Nenhuma dependência proprietária é necessária.

1. Obtenha o código do FFmpeg da tag `n8.1.2`: `https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n8.1.2.tar.gz`.
2. Confira o SHA-256: `9fd092511605bbebafe095ea6d38d9e40f34d12f7386e1258372df8be0576eb7`.
3. Extraia em uma pasta separada e execute:

```sh
python3 scripts/build_ffmpeg.py --source /caminho/FFmpeg-n8.1.2 --output ./build-media
python3 scripts/build_app.py --backend ./build-media --out ./build-app
```

O builder inclui um patch pequeno no FFmpeg para solicitar reprodução ONVIF por `Range: clock=...`. O código correspondente modificado, a configuração de compilação e a licença LGPL acompanham a distribuição. O app próprio e o FFmpeg se comunicam por processos/pipes, sem incorporar SDKs do SIM Play. Um mecanismo compatível pode ser recompilado e substituído em uma cópia local do pacote, respeitando assinatura e licenças.

A assinatura local é **ad hoc**, para integridade do pacote. Não equivale a Developer ID ou notarização Apple. O projeto não desativa Gatekeeper nem outras proteções globais.

## Testar

Veja `Tests/` e `docs/VALIDATION.md`. Os equipamentos simulados são locais e usam vídeos de teste gerados pelo próprio FFmpeg. Eles não são cadastros de produção e não são incluídos no perfil entregue.

## Licenças

Código próprio sob MIT; FFmpeg sob LGPL 2.1 ou posterior nesta configuração, sem `--enable-gpl` ou `--enable-nonfree`. Leia `THIRD_PARTY_NOTICES.md`. Licença de software não equivale a autorização de uso de marcas ou garantia sobre patentes de codecs em qualquer país. Antes de uma distribuição comercial ampla, revise as dependências e obrigações aplicáveis.
