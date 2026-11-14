FROM alpine:3.20
RUN apk add --no-cache lua5.3 && adduser -D -u 1000 tester
USER 1000
WORKDIR /src
