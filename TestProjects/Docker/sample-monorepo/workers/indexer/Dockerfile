FROM golang:1.23 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /indexer .

FROM gcr.io/distroless/static
COPY --from=build /indexer /indexer
CMD ["/indexer"]
