# Minimal justfile for hyperstack.rb

set dotenv-load := false
set shell := ["/bin/bash", "-cu"]

hypr := "ruby -Ilib hyperstack.rb"

create-vm1:
    {{hypr}} --vm 1 create

create-vm2:
    {{hypr}} --vm 2 create

delete-vm1:
    {{hypr}} --vm 1 delete

delete-vm2:
    {{hypr}} --vm 2 delete

watch:
    {{hypr}} watch

status:
    {{hypr}} status

test:
    {{hypr}} test
