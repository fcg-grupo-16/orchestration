# RabbitMQ da plataforma FCG com o plugin `rabbitmq_delayed_message_exchange` habilitado.
#
# O plugin é da COMUNIDADE (não vem na imagem oficial) e é exigido pelo delayed redelivery
# (second-level retry) do MassTransit no catalog-api. Estende a imagem oficial PINADA e casa
# a versão do plugin com a do broker (RabbitMQ 3.13 -> plugin v3.13.0).
FROM rabbitmq:3.13-management

# ADD com URL evita depender de curl/wget na imagem base. O .ez vai para o diretório de
# plugins da imagem oficial; `--offline` habilita em build (sem broker rodando).
ADD --chmod=644 \
    https://github.com/rabbitmq/rabbitmq-delayed-message-exchange/releases/download/v3.13.0/rabbitmq_delayed_message_exchange-3.13.0.ez \
    /opt/rabbitmq/plugins/
RUN rabbitmq-plugins enable --offline rabbitmq_delayed_message_exchange
