FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN go build -o /out/route-decider ./main.go

FROM alpine:3.20
RUN apk add --no-cache curl bash \
    && adduser -D -u 10001 app
USER app
COPY --from=build /out/route-decider /bin/route-decider
EXPOSE 8080
ENTRYPOINT ["/bin/route-decider"]
