FROM debian:stable

RUN apt update
RUN apt upgrade

RUN apt install -y bird3 iproute2

ARG BINARY_LOCATION
COPY $BINARY_LOCATION /usr/bin/bgpz

RUN mkdir /etc/bgpz

CMD [ "/bgpz" ]
