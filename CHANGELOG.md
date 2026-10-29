# Histórico

## 1.0.0-beta.3 — 2026-10-29

Consulta de canais deixa de impedir o cadastro quando o login funciona: se disponível, utiliza a quantidade de entradas informada na resposta de login legado, com nomes genéricos. Nova opção **Criar canais manualmente**, com quantidade definida pelo usuário, mantendo os nomes e identificadores existentes. Falha de consulta não provoca nova autenticação e a criação manual não afirma disponibilidade de vídeo. 69 verificações locais passaram, além da inspeção e decodificação de dois MKVs.

## 1.0.0-beta.2 — 2026-10-29

Cadastro de porta de serviço separado de ONVIF/RTSP, cliente de autenticação DVRIP legado, consulta de canais e transporte experimental de vídeo em duas conexões TCP, com demux DHAV no FFmpeg ARM64. Prévia, PNG e gravação MKV validados com vídeo sintético local. Porta e canais preservados em backups, mantendo os identificadores do mosaico nas consultas seguintes.

Falhas de autenticação não causam retry automático. Sessões e buffers têm limites e encerramento explícito. Histórico por serviço ainda não implementado; vídeo e áudio em gravador real ainda não homologados. Consulte `docs/SERVICE_PORT.md`.

## 1.0.0-beta.1 — 2026-10-29

Primeira implementação independente para macOS Apple Silicon: interface SwiftUI, ícone próprio, cliente RTSP/ONVIF, mosaico, snapshots, gravação MKV, reprodução local, áudio, PTZ e integração de histórico ONVIF. Configuração JSON, backup criptografado e restauração com prévia/mesclagem.

Esta é uma versão inicial de validação, não uma versão homologada para todos os equipamentos. Consulte `docs/VALIDATION.md` para os resultados e limites.
