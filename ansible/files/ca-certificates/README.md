# Corporate CA certificates

Put your PEM-encoded corporate root CA here as `corp-root-ca.crt` to use the
`corp-root-ca` software item. The request validator rejects requests for that
item until the file is present.

Only public certificates belong here, never private keys.
