# Validação da primeira versão

Data: 29/10/2026. Os resultados abaixo referem-se ao ARM; o pacote Intel ainda não foi validado em hardware real. Processo e backend compilados para ARM64, sem Rosetta e sem componentes do SIM Play. Não há afirmação de paridade completa com o SIM Play ou certificação ONVIF.

## Resultado desta execução

### Atualização beta.3 — consulta opcional de canais

Passaram **69 verificações Swift**, mais inspeção e decodificação integral de dois MKVs sintéticos. Sete verificações novas cobrem a quantidade informada no login, recuperação após fechamento da conexão de consulta, RPC não suportado, ausência de nova autenticação, recusa de credenciais mesmo com quantidade no cabeçalho e cadastro manual com preservação de nomes/IDs e validação dos limites. O relato do usuário confirma que o login foi aceito no seu equipamento, mas ainda não houve confirmação de vídeo nem observação direta do tráfego real; a causa específica da falha da consulta permanece desconhecida.

### Atualização beta.2 — porta de serviço

Passaram **62 verificações Swift**, mais inspeção de codec/duração e decodificação integral de dois MKVs no script Python (gravação por duração e finalização manual). Incluem conexão TCP local real, falha de autenticação sem retry, timeout, RPC fragmentado, mensagens inválidas, compatibilidade de backups, associação de socket de mídia, keep-alive, prévia nativa, PNG e gravação de serviço independente do painel. O backend desta versão inclui o demuxer DHAV.

Com o fixture ONVIF ativo, `python3 scripts/run_checks.py --backend build-media-service --fixture` concluiu **67 verificações Swift**, preservando os cinco testes de integração ONVIF anteriores. As inspeções dos dois MKVs também passaram nesta execução final.

Não houve validação no DVR do usuário: a política do ambiente bloqueou o teste de rede. O transporte de vídeo é experimental e o histórico por serviço não foi implementado. Detalhes e instruções em [SERVICE_PORT.md](SERVICE_PORT.md). A interface foi compilada, sem nova inspeção visual nesta etapa.

### Validação anterior beta.1

**30 verificações passaram**, incluindo a integração local ONVIF. Na interface foram observados: prévia/importação com substituição, dois vídeos RTSP simultâneos, gravação finalizada com estado Arquivo salvo, backup criptografado salvo e reprodução histórica no painel. Os arquivos MKV foram inspecionados com ffprobe e decodificados sem erros. O app e o FFmpeg são ARM64; a assinatura ad hoc do pacote foi verificada.

## Testes automatizados

Os testes cobrem configuração JSON sem senha, backup criptografado completo, senha incorreta, integridade/tamper, limites de KDF, senha curta, IDs repetidos, referências de mosaico, URLs com credenciais/tokens ou host divergente, XML inválido/DTD, reconstrução de JPEGs divididos entre leituras, persistência, restauração, mesclagem e rollback de credenciais quando a operação falha.

O cliente ONVIF também é testado contra um servidor local determinístico: GetServices, GetProfiles, GetStreamUri, GetRecordings, GetReplayUri, ContinuousMove e Stop. Esses testes verificam o protocolo; não substituem testes em hardware real.

Execute `python3 scripts/run_checks.py`. Para integração de rede, inicie o fixture e use `--fixture`.

## Vídeo e gravação de teste

O backend recebe um stream RTSP de um servidor local, contendo um padrão sintético MPEG-4 criado com o próprio FFmpeg. A gravação MKV e o replay por horário são verificados com ffprobe e decodificação dos arquivos, não apenas pela existência do arquivo. O fixture registra se o comando PLAY contém `Require: onvif-replay` e `Range: clock=...`.

Para reproduzir o ambiente:

```sh
build-media/ffmpeg -f lavfi -i testsrc2=size=640x360:rate=10 -t 3 -c:v mpeg4 -q:v 5 -f m4v /tmp/vigia-fixture.m4v
python3 Tests/fixture_server.py --video /tmp/vigia-fixture.m4v --events /tmp/vigia-fixture-events.json
```

O fixture escuta somente `127.0.0.1`, portas 18780 (ONVIF) e 18554 (RTSP). Nenhum equipamento real é alterado.

## Ainda depende de validação em hardware

- Conexão com os modelos reais do usuário, autenticação HTTP Digest/WS-Security, relógio e permissões de cada equipamento.
- Reprodução H.264/HEVC via RTSP de equipamentos reais, aceleração VideoToolbox e uso de energia sob carga prolongada.
- Áudio real, PTZ físico e precisão de reprodução/exportação histórica do gravador.
- Descoberta multicast em redes/VLANs diferentes.
- Gravação prolongada, perda de rede e ambientes com 16 canais simultâneos.
- Execução em outros Macs e versões de macOS além do ambiente usado no desenvolvimento.

Não há testes de autonomia de bateria. O modo Econômico reduz resolução/FPS da prévia; a gravação preserva o stream original.
