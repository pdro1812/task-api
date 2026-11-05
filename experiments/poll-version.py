"""Consulta /version a cada INTERVAL segundos e grava "epoch build" (ou "epoch ERRO:<motivo>") por linha.

Cada consulta abre uma conexão nova, para que o balanceamento do Service distribua entre os pods.
Uso: python3 experiments/poll-version.py http://IP:30080 saida.log [intervalo=0.1]  (encerre com SIGTERM)
"""
import json
import signal
import sys
import time
import urllib.request

url, out = sys.argv[1].rstrip('/') + '/version', sys.argv[2]
interval = float(sys.argv[3]) if len(sys.argv) > 3 else 0.1
running = True
signal.signal(signal.SIGTERM, lambda *_: globals().__setitem__('running', False))

with open(out, 'w', buffering=1) as fh:
    next_t = time.time()
    while running:
        t = time.time()
        try:
            with urllib.request.urlopen(url, timeout=1) as r:
                fh.write(f'{t:.3f} {json.load(r)["build"]}\n')
        except Exception as e:  # noqa: BLE001 — qualquer falha conta como resposta inválida
            fh.write(f'{t:.3f} ERRO:{type(e).__name__}\n')
        next_t += interval
        time.sleep(max(0.0, next_t - time.time()))
