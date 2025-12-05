FROM debian:stable

RUN apt update
RUN apt upgrade

RUN apt install -y bird3

RUN mkdir -p /run/bird

VOLUME [ "/etc/" ]

CMD [ "bash" ]
