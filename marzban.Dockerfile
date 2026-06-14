FROM gozargah/marzban:latest
# Install our private CA so Marzban's cert validator accepts the panel cert.
# The CA only covers 127.0.0.1/localhost and is never used outside this box.
COPY secrets/panel-tls/ca.crt /usr/local/share/ca-certificates/finfa-panel-ca.crt
RUN update-ca-certificates
