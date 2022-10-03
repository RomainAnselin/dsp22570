FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y
RUN apt-get upgrade -y
RUN apt install -y apt-utils

RUN sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf

RUN sysctl -p
RUN apt-get install -y iptables
#RUN systemctl enable iptables

ENTRYPOINT [ "tail", "-F", "/dev/null" ]

