# Validação da primeira versão

Data: 29/10/2026. Processo e backend compilados para ARM64, sem Rosetta e sem componentes do SIM Play. Não há afirmação de paridade completa com o SIM Play ou certificação ONVIF.

## Resultado desta execução

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
