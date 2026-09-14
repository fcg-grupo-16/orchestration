#!/usr/bin/env python3
"""Valida a topologia declarativa do RabbitMQ (docker/rabbitmq/definitions.json).

POR QUE EXISTE: este arquivo é importado no BOOT do broker (`load_definitions`). JSON quebrado ou
topologia incompleta não aparece em lugar nenhum até o container subir — e o modo de falha é mudo:
o evento publicado cai num exchange sem binding e é DESCARTADO EM SILÊNCIO.

⚠️ O dead-lettering desta plataforma é por POLICY, não por `x-dead-letter-exchange` nos `arguments`
da fila. Uma checagem que olhasse `arguments` reprovaria as duas filas CORRETAS. O motivo está
documentado no próprio definitions.json: os argumentos participam da checagem de equivalência do
`queue.declare`, e o MassTransit declara estas filas sem argumento nenhum — divergir aqui faz o
publisher morrer com PRECONDITION_FAILED. Policies são aplicadas pelo servidor por fora do declare.

Uso: python3 .github/scripts/validar-definitions-rabbitmq.py [caminho]
"""
import json
import re
import sys

caminho = sys.argv[1] if len(sys.argv) > 1 else "docker/rabbitmq/definitions.json"

try:
    with open(caminho, encoding="utf-8") as fh:
        d = json.load(fh)
except json.JSONDecodeError as e:
    sys.exit(f"ERRO: {caminho} não é JSON válido: {e}")

erros = []

filas = {q["name"] for q in d.get("queues", [])}
exchanges = {e["name"] for e in d.get("exchanges", [])}
politicas = d.get("policies", [])

# 1) O broker não semeia mais o usuário `guest` quando load_definitions está ligado: com a lista
#    vazia ele sobe com ZERO usuários e TODOS os serviços falham a autenticação.
if not d.get("users"):
    erros.append("nenhum usuário declarado: com load_definitions o broker NÃO cria o `guest` padrão")
if not d.get("vhosts"):
    erros.append("nenhum vhost declarado")

# 2) Toda fila de trabalho (≠ DLQ) precisa de dead-lettering — por POLICY.
trabalho = sorted(f for f in filas if not f.endswith("-dlq"))
for fila in trabalho:
    casadas = [
        p for p in politicas
        if p.get("apply-to") in ("queues", "all")
        and p.get("definition", {}).get("dead-letter-exchange")
        and re.search(p.get("pattern", ""), fila)
    ]
    if not casadas:
        erros.append(f"fila de trabalho '{fila}' não é coberta por nenhuma policy com dead-letter-exchange")
        continue
    dlx = casadas[0]["definition"]["dead-letter-exchange"]
    if dlx not in exchanges:
        erros.append(f"policy de '{fila}' aponta para o exchange '{dlx}', que não é declarado")

# 3) A policy NÃO pode casar a própria DLQ: ela dead-letteraria para si mesma (loop).
for p in politicas:
    if not p.get("definition", {}).get("dead-letter-exchange"):
        continue
    for dlq in (f for f in filas if f.endswith("-dlq")):
        if re.search(p.get("pattern", ""), dlq):
            erros.append(f"policy '{p['name']}' casa a DLQ '{dlq}': loop de dead-letter")

# 4) O DLX precisa ter binding para alguma DLQ, senão a mensagem dead-letterada se perde —
#    exatamente o que a DLQ existe para evitar.
for p in politicas:
    dlx = p.get("definition", {}).get("dead-letter-exchange")
    if not dlx:
        continue
    tem = any(
        b.get("source") == dlx
        and b.get("destination_type") == "queue"
        and b.get("destination") in filas
        for b in d.get("bindings", [])
    )
    if not tem:
        erros.append(f"exchange '{dlx}' não tem binding para nenhuma fila: mensagem dead-letterada se perderia")

# 5) Toda fila precisa ser alcançável por algum binding, senão nada chega nela.
for fila in trabalho:
    if not any(b.get("destination") == fila and b.get("destination_type") == "queue"
               for b in d.get("bindings", [])):
        erros.append(f"fila '{fila}' não é destino de binding nenhum: nada chegaria nela")

# 6) Binding não pode referenciar exchange/fila inexistente.
for b in d.get("bindings", []):
    if b.get("source") not in exchanges:
        erros.append(f"binding referencia exchange inexistente: '{b.get('source')}'")
    destino = b.get("destination")
    conhecido = filas if b.get("destination_type") == "queue" else exchanges
    if destino not in conhecido:
        erros.append(f"binding aponta para {b.get('destination_type')} inexistente: '{destino}'")

if erros:
    print(f"{caminho}: {len(erros)} problema(s)", file=sys.stderr)
    for e in erros:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(f"{caminho}: JSON válido; {len(trabalho)} fila(s) de trabalho com dead-lettering por policy, "
      f"{len(d.get('bindings', []))} binding(s) consistentes")
