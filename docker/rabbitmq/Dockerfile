# RabbitMQ da plataforma FCG com o plugin `rabbitmq_delayed_message_exchange` habilitado.
#
# O plugin é da COMUNIDADE (não vem na imagem oficial) e é exigido pelo delayed redelivery
# (second-level retry) do MassTransit no catalog-api. Estende a imagem oficial pinada no PATCH
# (reprodutibilidade) e casa a versão do plugin com a do broker (RabbitMQ 3.13.7 -> plugin v3.13.0).
FROM rabbitmq:3.13.7-management

# ADD com URL evita depender de curl/wget na imagem base; --checksum verifica a integridade do
# artefato (supply-chain). O .ez vai para o diretório de plugins da imagem oficial; `--offline`
# habilita em build (sem broker rodando).
ADD --chmod=644 \
    --checksum=sha256:3479180df03fa830fd59ccf638a60eee8f0e8261524a8616685522d7b8d9a9ee \
    https://github.com/rabbitmq/rabbitmq-delayed-message-exchange/releases/download/v3.13.0/rabbitmq_delayed_message_exchange-3.13.0.ez \
    /opt/rabbitmq/plugins/
RUN rabbitmq-plugins enable --offline rabbitmq_delayed_message_exchange
