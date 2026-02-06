#!/bin/bash
# Encrypt/Decrypt secrets using age
# Key: /home/diego/Mounts/Git/vault/A0_keys/age/keys.txt

AGE_KEY="/home/diego/Mounts/Git/vault/A0_keys/age/keys.txt"
AGE_PUB="age1u575hx8h4t5cgle2uznmyfy75e7cgd02h9t5dax506luz9e05vlqxtd7pq"

encrypt() {
    local input="$1"
    local output="${input%.txt}.age"
    [[ "$input" != *.txt ]] && output="${input}.age"
    age -r "$AGE_PUB" -o "$output" "$input" && echo "Encrypted: $output" && rm -f "$input"
}

decrypt() {
    local input="$1"
    local output="${input%.age}"
    age -d -i "$AGE_KEY" -o "$output" "$input" && echo "Decrypted: $output"
}

case "$1" in
    -e|--encrypt) encrypt "$2" ;;
    -d|--decrypt) decrypt "$2" ;;
    -a|--all-decrypt)
        for f in $(find . -name "secrets.age"); do
            echo "Decrypting $f..."
            age -d -i "$AGE_KEY" "$f"
            echo "---"
        done
        ;;
    *)
        echo "Usage: $0 [-e|--encrypt] <file>   Encrypt file"
        echo "       $0 [-d|--decrypt] <file>   Decrypt file"
        echo "       $0 [-a|--all-decrypt]      Show all secrets"
        ;;
esac
