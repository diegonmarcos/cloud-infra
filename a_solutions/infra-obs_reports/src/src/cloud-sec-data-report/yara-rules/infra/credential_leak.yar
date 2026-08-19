rule exposed_ssh_private_key {
    meta:
        description = "Detects exposed SSH private keys"
        REDACTED
        REDACTED

    strings:
        $rsa = "REDACTED
        REDACTED
        REDACTED" ascii
        $dsa = "REDACTED
        REDACTED

    condition:
        any of them
}

REDACTED
    meta:
        REDACTED
        REDACTED
        REDACTED

    strings:
        REDACTED
        REDACTED
        REDACTED
        REDACTED
        REDACTED
        REDACTED

    condition:
        any of them
}

REDACTED
    meta:
        REDACTED
        REDACTED
        REDACTED

    strings:
        REDACTED
        REDACTED
        REDACTED
        REDACTED
        REDACTED
        REDACTED
        REDACTED
        REDACTED

    condition:
        2 of them
}

REDACTED
    meta:
        REDACTED
        REDACTED
        REDACTED

    strings:
        REDACTED
        REDACTED" ascii
        $s3 = "REDACTED
        $s4 = "REDACTED" ascii

    condition:
        $s1 and any of ($s2, $s3, $s4)
}
