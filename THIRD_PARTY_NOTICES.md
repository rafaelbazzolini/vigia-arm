# Componentes de terceiros

O aplicativo Vigia ARM e seus recursos foram implementados para este projeto. Não há código, SDK, binários, logotipos ou recursos do SIM Play/Intelbras/Dahua no pacote.

O vídeo utiliza um processo FFmpeg, compilado do código `FFmpeg/FFmpeg`, tag `n8.1.2`, sob **LGPL 2.1 ou posterior**. A compilação desabilita componentes GPL e nonfree. O script `scripts/build_ffmpeg.py` registra todas as flags e a alteração no cliente RTSP para a reprodução ONVIF por horário UTC. O arquivo `ffmpeg-8.1.2-vigia-source.tar.gz` contém o código-fonte correspondente modificado. `BUILD.json` e `COPYING.LGPLv2.1` também acompanham o backend. O código correspondente deve acompanhar cada distribuição deste binário; não redistribua só o executável e omita os avisos.

FFmpeg é marca de seus titulares. O projeto utiliza frameworks fornecidos pelo macOS, não os redistribui. Os nomes ONVIF/RTSP descrevem interoperabilidade; o app não foi submetido à certificação ONVIF e não deve usar selos de conformidade.

Referências de implementação: especificações públicas ONVIF Device/Media/PTZ/Recording/Replay e os protocolos RTSP/RTP. Não se afirma a realização de um processo formal de sala limpa auditado. Implementar um cliente independente não equivale a copiar a implementação do fornecedor.

O cliente experimental de porta de serviço usa referências públicas de interoperabilidade: DahuaConsole (MIT, Copyright (c) 2021 bashis; aviso em `LICENSES/DahuaConsole-MIT.txt`), documentação imou-life e fatos do protocolo descritos no projeto TaniDVR. Nenhum console, SDK ou binário desses projetos é executado pelo app. Veja `docs/SERVICE_PORT.md` para escopo e atribuição. O demuxer DHAV é parte do FFmpeg LGPL incluído nesta compilação.

As permissões de uso do equipamento, da rede e do conteúdo gravado continuam sendo responsabilidade do usuário. A disponibilidade pública de especificações e licenças livres não substitui a análise de outras obrigações aplicáveis, incluindo eventuais patentes de codecs.
