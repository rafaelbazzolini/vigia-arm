# Porta de serviço: implementação experimental

A versão 1.0.0-beta.2 adiciona um cliente independente do protocolo **DVRIP legado**, normalmente na porta TCP 37777. Uma porta encaminhada, como 12000, pode ser informada diretamente. O número da porta não identifica sozinho o protocolo. Esta implementação não é o protocolo Sofia/Xiongmai da porta 34567, nem o enquadramento DHIP da porta 5000.

## Como cadastrar

1. Em **Adicionar equipamento**, informe nome, endereço, usuário e senha do gravador.
2. Na seção **Porta de serviço • experimental**, ative **Cadastrar conexão DVRIP legado** e informe a porta de serviço. Não coloque a porta de serviço no campo RTSP.
3. Clique em **Testar acesso e consultar canais**. Há uma tentativa de autenticação por ação; senhas recusadas não provocam tentativas automáticas.
4. Se a consulta for aceita, os canais aparecem no cadastro. Salve o equipamento e abra um canal na lista lateral.
5. O substream fica selecionado por padrão. Desative a opção se o equipamento só disponibilizar o stream principal. A mudança se aplica às próximas conexões.

**Beta.3:** a consulta dos nomes não é mais obrigatória. Quando o login legado informa a quantidade de entradas, o app usa esse número como alternativa e avisa que os nomes são genéricos. Se o número não vier no login, ou se preferir cadastrar diretamente, preencha **Quantidade de canais** e clique em **Criar canais manualmente**. Informe a quantidade real do gravador; depois salve e teste o vídeo. O cadastro não confirma imagem, conectividade ou permissão de cada entrada, não altera o equipamento e não envia outra tentativa de login. Canais já cadastrados mantêm seus identificadores e nomes no cadastro manual.

Os canais de serviço, suas posições e a porta fazem parte do JSON e do backup completo criptografado. As senhas permanecem no Chaves ou dentro do backup criptografado. Configurações antigas continuam legíveis. Versões anteriores do app não reproduzem canais de serviço.

## Etapas e limites

- Conexão TCP e desafio de autenticação, com digest compatível com o protocolo legado.
- Consulta somente de leitura `configManager.getConfig`, tabela `ChannelTitle`.
- Segunda conexão TCP vinculada à sessão autenticada para receber vídeo binário.
- Solicitação do canal principal/substream, enquadramento de mensagens e extração do payload para o demuxer DHAV do FFmpeg.
- Prévia, snapshot e gravação MKV usam o mesmo mecanismo nativo de apresentação do app. Cada consumidor abre sua própria sessão; iniciar gravação ou áudio pode consumir conexões adicionais no gravador.
- Mensagens e filas têm limites; leituras possuem prazo e conexões são canceladas ao fechar o painel. O produtor usa um pipe com contrapressão, sem acumular vídeo ilimitadamente.
- Para este caminho experimental, a prévia usa decodificação em software. Não foi medida a autonomia de bateria e não se afirma vantagem energética sobre o app Intel.
- **Não implementado por esta porta:** busca/reprodução de gravações remotas, exportação do histórico, PTZ, P2P e conta do fabricante. Histórico e PTZ existentes continuam dependendo de ONVIF, cadastrado separadamente.
- Áudio percorre o mesmo transporte e depende dos codecs disponíveis no backend, mas não foi validado com áudio de um gravador real.
- Modelos que usam uma variante diferente de login, exigem criptografia proprietária ou não expõem os comandos legados podem recusar esta versão. O app não oferece fallback de senha em texto claro.

## Validação realizada

Um servidor próprio, com credenciais e imagens sintéticas, escuta exclusivamente em `127.0.0.1`. O teste separa cabeçalhos em várias leituras TCP, autentica, consulta os canais, vincula a segunda conexão, transmite mensagens binárias DHAV e encerra as sessões. A prévia gera uma imagem `NSImage`, o snapshot é validado como PNG e o MKV é inspecionado com ffprobe e completamente decodificado.

O teste verifica o caminho implementado, **não certifica compatibilidade com um equipamento real**. O ambiente de desenvolvimento bloqueou a conexão ao gravador do usuário; não houve validação de autenticação ou vídeo nele. Não foram contornadas as restrições de rede. A interface nova foi compilada, mas não foi inspecionada visualmente nesta etapa por indisponibilidade do controle de interface.

Execute:

```sh
python3 scripts/run_checks.py
python3 scripts/run_checks.py --backend build-media-service
```

A segunda forma requer o backend recompilado com `--enable-demuxer=dhav`. Nenhum teste usa o endereço ou as credenciais de produção.

## Referências públicas

- [DahuaConsole, net.py](https://github.com/mcw0/DahuaConsole/blob/master/net.py) e [dahua_logon_modes.py](https://github.com/mcw0/DahuaConsole/blob/master/dahua_logon_modes.py): formato do desafio, autenticação e enquadramento RPC. Licença MIT, Copyright (c) 2021 bashis; aviso preservado em `LICENSES/DahuaConsole-MIT.txt`. O console não é incluído nem executado pelo app.
- [Documentação de interoperabilidade do imou-life](https://github.com/home-assistant-plugins/imou-life/blob/main/docs/lan-dvrip-talk.md): confirmação pública da composição dos digests de login.
- [TaniDVR](https://tanidvr.sourceforge.net/) e [hlprotocol.c](https://github.com/arthar360/TaniDVR/blob/master/src/hlprotocol.c): referência dos campos das mensagens legadas de associação, seleção de canal, dados e keep-alive. Projeto GPL-3.0-or-later, Copyright (c) 2011–2015 Daniel Mealha Cabrita. Não há inclusão, ligação, tradução ou distribuição de seu código ou binários; a implementação Swift foi escrita para este projeto a partir dos fatos do protocolo.
- [Demuxer DHAV do FFmpeg](https://github.com/FFmpeg/FFmpeg/blob/n8.1.2/libavformat/dhav.c), incluído no backend LGPL e em seu código correspondente.

Nenhuma biblioteca proprietária, assembly, ícone ou SDK do SIM Play foi incorporado. Não se afirma processo formal de sala limpa auditado nem homologação do fabricante.
