FROM alpine:latest

RUN apk add --no-cache openssh-client iproute2

WORKDIR /app

COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]
