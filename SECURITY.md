# Segurança e privacidade

- As senhas de equipamentos ficam no Chaves do macOS. O JSON de configuração não as contém.
- Backups completos usam AES-256-GCM autenticado e PBKDF2-HMAC-SHA256, com salt aleatório e limites de tamanho/iterações na leitura.
- A senha de backup não é armazenada e não pode ser recuperada.
- Endpoints ONVIF e URLs de vídeo devem pertencer ao equipamento cadastrado; redirecionamentos HTTP não são seguidos. XML com DTD/entidades é recusado.
- HTTPS usa a validação normal de certificados do macOS. Não existe um botão para ignorá-la.
- HTTP/RTSP comuns não fornecem criptografia de transporte. Use uma LAN confiável ou VPN. O app não abre portas no roteador.
- O modo de serviço experimental usa TCP sem TLS; o desafio/digest legado não equivale a criptografia do vídeo ou a autenticação moderna. Use rede confiável ou VPN. Há uma tentativa de login por ação, sem downgrade para senha em texto claro. O FFmpeg recebe somente o vídeo por pipe, sem receber as credenciais deste modo.
- Não há telemetria. O FFmpeg não escreve URLs/credenciais em logs do app; ainda assim, a URL autenticada é passada ao processo auxiliar e pode ser visível a ferramentas com permissão de inspecionar processos da mesma sessão. Não use credenciais administrativas desnecessárias.
- O programa não oferece proteção contra comprometimento do próprio Mac ou contra usuários com privilégios elevados.
- Arquivos de vídeo e JSON sem senha devem ser guardados em local apropriado. O backup criptografado também contém endereços, nomes e configuração.

Para relatar uma falha, use um canal privado do repositório quando disponível. Se não houver, solicite um canal sem publicar credenciais ou detalhes exploráveis. O projeto não possui SLA de segurança.
