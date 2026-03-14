FROM debian:stable

RUN apt update -y
RUN apt upgrade -y

RUN apt install -y bird3 iproute2

RUN mkdir -p /run/bird

VOLUME [ "/etc/" ]

CMD [ "bash" ]
