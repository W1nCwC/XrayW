FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X github.com/W1nCwC/XrayW/cmd.version=${VERSION}" -o /out/XrayW .

FROM alpine:3
RUN apk add --no-cache ca-certificates tzdata && mkdir -p /etc/XrayW
COPY --from=build /out/XrayW /usr/local/bin/XrayW
COPY release/config/ /etc/XrayW/
ENV XRAY_LOCATION_ASSET=/etc/XrayW
WORKDIR /etc/XrayW
ENTRYPOINT ["/usr/local/bin/XrayW", "-c", "/etc/XrayW/config.yml"]
