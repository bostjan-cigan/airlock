FROM golang:1.22 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /notes ./cmd/notes

FROM gcr.io/distroless/static
COPY --from=build /notes /notes
EXPOSE 3000
CMD ["/notes"]
