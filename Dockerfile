FROM ubuntu:18.04

ENV CONFLUENT_VERSION=5.0 \
    KAFKA_BIN_DIR=/opt/kafka/bin \
    KAFKA_CONFIG_DIR=/etc/bmw/kafka \
    KAFKA_DATA_DIR=/var/lib/kafka \
    KAFKA_LOG_DIR=/var/log/kafka \
    KAFKA_EXPORTER_VERSION=2_0_0 \
    JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64

# install pre-requisites and Confluent
RUN set -x \
    && apt-get update \
    && apt-get install -y openjdk-8-jre-headless wget netcat-openbsd software-properties-common \
    && wget -qO - http://packages.confluent.io/deb/$CONFLUENT_VERSION/archive.key | apt-key add - \
    && add-apt-repository "deb [arch=amd64] http://packages.confluent.io/deb/$CONFLUENT_VERSION stable main" \
    && apt-get update \
    && apt-get install -y confluent-platform-oss-2.11

# create required directories and set privileges
COPY bin/* ${KAFKA_BIN_DIR}/
COPY config/* ${KAFKA_CONFIG_DIR}/
RUN set -x \
    && mkdir -p ${KAFKA_DATA_DIR} \
    && chown -R :root ${KAFKA_CONFIG_DIR} ${KAFKA_DATA_DIR} \
    && chmod -R g+rwx ${KAFKA_CONFIG_DIR} ${KAFKA_DATA_DIR} \
    && chmod +x ${KAFKA_BIN_DIR}/*.sh

RUN set -x \
    && apt-get update \
    && apt-get install -y curl


#Giving Read permission for others for log directory 
RUN chmod -R 755 /var/log/kafka \
    && chmod -R 755 /var/log/confluent
