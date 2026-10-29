# Vigia ARM

Cliente de vídeo independente para **macOS 14+ em Macs Apple Silicon e Intel**, escrito em Swift/SwiftUI. Nome provisório do projeto. Não é uma versão do SIM Play, não incorpora seus assemblies, recursos, SDKs ou ícones e não possui vínculo com a Intelbras/Dahua.

## Funções

- Cadastro de câmeras e gravadores por endereço, usuário e senha.
- Descoberta ONVIF na rede local e consulta dos perfis Media1.
- Cadastro manual de URLs RTSP, com usuário e senha em campos separados.
- Porta de serviço DVRIP legado experimental: autenticação, consulta dos canais e vídeo ao vivo pelo transporte binário, sem SDK do fabricante. Consulte [configuração, testes e limites](docs/SERVICE_PORT.md).
- Mosaicos de 1, 4, 9, 12, 16, 20, 36 ou 64 canais e layouts personalizados; favoritos e troca de painéis por arraste.
- Modos Econômico, Equilibrado e Detalhado para a prévia; vídeo H.264, HEVC e MPEG-4 conforme a compilação do FFmpeg.
- Para reduzir CPU, a prévia limita resolução e quadros por segundo sem ampliar substreams menores. Mudanças de qualidade são aplicadas ao abrir ou reconectar o canal; gravações continuam copiando o stream recebido.
- Captura de imagem PNG; gravação MP4 com vídeo sem reencodificação. Na porta de serviço, a gravação solicita o stream principal; em RTSP grava o stream cadastrado. Áudio, quando presente, é convertido para AAC.
- Proteção opcional da interface por senha local; streams e gravações continuam enquanto bloqueado.
- Reprodução de arquivos locais e monitoramento de áudio de um canal.
- Consulta de fontes de gravação, reprodução a partir de data/hora e exportação de período por ONVIF Profile G.
- Comandos PTZ curtos de direção/zoom no menu de contexto do painel, quando o perfil oferece PTZ.
- Exportação de configuração JSON sem senhas.
- Backup completo criptografado com AES-256-GCM, senha de backup e PBKDF2-HMAC-SHA256 (300 mil iterações, salt aleatório).
- Prévia de importação, mesclagem ou substituição da configuração; senhas no Chaves do macOS.

**O suporte real às funções ONVIF depende do equipamento. Implementação não significa homologação universal.** Consulte `docs/VALIDATION.md` para saber exatamente o que foi testado. A primeira versão não possui Conta Intelbras, P2P do fabricante, eventos inteligentes ou conversor de backup proprietário do SIM Play. Gravações remotas exigem os serviços Recording/Replay (Profile G); muitos gravadores não os oferecem, mesmo quando têm ONVIF para vídeo ao vivo.

## Baixar e abrir o app

Na página de releases, escolha o arquivo `macOS-arm64.zip` para Macs Apple Silicon (M1, M2, M3, M4, M5 etc.) ou `macOS-x86_64.zip` para Macs Intel. Consulte **Sobre Este Mac** no menu Apple se tiver dúvida. Extraia o ZIP e abra `VigiaARM.app`. Os pacotes possuem assinatura ad hoc e não são notarizados; o macOS pode exigir confirmação de abertura em Ajustes do Sistema > Privacidade e Segurança. A versão Intel ainda precisa de validação em um Mac Intel real.


Abra `VigiaARM.app`. Adicione um equipamento, informe o endereço e as credenciais e clique em **Buscar canais ONVIF**, ou adicione uma URL RTSP manual. Salve, selecione um painel e abra o canal na lista lateral. A descoberta não envia senhas; as conexões usam as credenciais cadastradas.

Os perfis ONVIF podem representar substreams diferentes do mesmo canal. Os caminhos RTSP de exemplo são sugestões e não garantem compatibilidade com um modelo.

Se você só possui uma **porta de serviço**, ative a seção correspondente no cadastro, informe essa porta e consulte os canais. Salve e abra um canal na lista lateral. A beta.2 foi testada com um servidor sintético local; o acesso ao gravador do usuário permaneceu bloqueado pelo ambiente. Histórico pela porta de serviço ainda não está implementado. Não trate a porta de serviço como RTSP. Leia `docs/SERVICE_PORT.md` antes de testar.

Na beta.3, se o login for aceito mas a consulta falhar, o app aproveita a quantidade de canais informada no login, quando disponível. Também é possível informar a quantidade real de canais e clicar em **Criar canais manualmente**. Salve o equipamento e teste um canal na lateral. Nomes genéricos e cadastro manual não significam que o vídeo foi validado.

Na aba **Backups**, exporte JSON sem senhas ou crie um backup completo criptografado. A senha do backup não é salva nem recuperável. A importação mostra os equipamentos antes de aplicar; ela não altera os dispositivos físicos. Não importe arquivos de origem desconhecida.

A configuração fica em `~/Library/Application Support/VigiaARM/configuration.json`; as senhas ficam no Chaves, serviço `io.github.rafaelbazzolini.vigia-arm`. Um build de desenvolvimento pode indicar outra pasta de dados. Gravações e imagens são salvas somente onde você escolher. O programa não envia telemetria nem publica configurações.

## Compilar

Requer macOS, Xcode/Command Line Tools, Python 3.9+ e FFmpeg compilado conforme o script do projeto. Nenhuma dependência proprietária é necessária.

1. Obtenha o código do FFmpeg da tag `n8.1.2`: `https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n8.1.2.tar.gz`.
2. Confira o SHA-256: `9fd092511605bbebafe095ea6d38d9e40f34d12f7386e1258372df8be0576eb7`.
3. Extraia em uma pasta separada e execute:

```sh
# Apple Silicon; use uma cópia separada do código-fonte para cada arquitetura.
python3 scripts/build_ffmpeg.py --source /caminho/ffmpeg-arm --output ./build-media-arm --arch arm64
python3 scripts/build_app.py --backend ./build-media-arm --out ./build-app-arm --arch arm64
python3 scripts/package_release.py --build ./build-app-arm --out ./build-release --arch arm64

# Intel (x86_64)
python3 scripts/build_ffmpeg.py --source /caminho/ffmpeg-intel --output ./build-media-intel --arch x86_64
python3 scripts/build_app.py --backend ./build-media-intel --out ./build-app-intel --arch x86_64
python3 scripts/package_release.py --build ./build-app-intel --out ./build-release --arch x86_64
```

O builder inclui um patch pequeno no FFmpeg para solicitar reprodução ONVIF por `Range: clock=...`. O código correspondente modificado, a configuração de compilação e a licença LGPL acompanham a distribuição. O app próprio e o FFmpeg se comunicam por processos/pipes, sem incorporar SDKs do SIM Play. Um mecanismo compatível pode ser recompilado e substituído em uma cópia local do pacote, respeitando assinatura e licenças.

A assinatura local é **ad hoc**, para integridade do pacote. Não equivale a Developer ID ou notarização Apple. O projeto não desativa Gatekeeper nem outras proteções globais.

## Testar

Veja `Tests/` e `docs/VALIDATION.md`. Os equipamentos simulados são locais e usam vídeos de teste gerados pelo próprio FFmpeg. Eles não são cadastros de produção e não são incluídos no perfil entregue.

## Licenças

Código próprio sob MIT; FFmpeg sob LGPL 2.1 ou posterior nesta configuração, sem `--enable-gpl` ou `--enable-nonfree`. Leia `THIRD_PARTY_NOTICES.md`. Licença de software não equivale a autorização de uso de marcas ou garantia sobre patentes de codecs em qualquer país. Antes de uma distribuição comercial ampla, revise as dependências e obrigações aplicáveis.
