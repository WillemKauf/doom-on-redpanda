FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/bridge ./...

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/bridge /bridge
EXPOSE 8080
ENTRYPOINT ["/bridge"]
