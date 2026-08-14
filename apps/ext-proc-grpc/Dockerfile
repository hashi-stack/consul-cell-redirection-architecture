FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN go build -o /out/ext-proc-grpc ./main.go

FROM alpine:3.20
RUN adduser -D -u 10001 app
USER app
COPY --from=build /out/ext-proc-grpc /bin/ext-proc-grpc
EXPOSE 50051
ENTRYPOINT ["/bin/ext-proc-grpc"]
