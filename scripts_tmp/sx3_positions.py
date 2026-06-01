#!/usr/bin/env python3
# Extrai, do dicionário SX3 (arquivo "SC3010 - Dicionário de Dados.csv"),
# a lista de campos por tabela ORDENADA por X3_ORDEM (ordem física do SELECT *),
# e cruza com a 1a linha real do CSV correspondente para validar nº de colunas.
#
# Uso: python sx3_positions.py
import csv
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DICT_PATH = os.path.join(ROOT, "SC3010 - Dicionário de Dados.csv")

# tabela -> arquivo CSV de dados (None = não disponível na raiz)
CSV_FILES = {
    "CC2": "CC2010.csv",
    "SA1": "SA1010.csv",
    "SA3": "SA3010.csv",
    "SB1": "SB1010.csv",
    "SBM": "SBM010.csv",
    "SC5": "SC5010.csv",
    "SC6": "SC6010.csv",
    "SF2": "SF2010.csv",
    "SD2": "SD2010.csv",
    "SF4": "SF4010.csv",
    "SX5": "SX5010.csv",
    "SZ1": "SZ1010.csv",
    "ZA7": "ZA7010.csv",
}

# campos que interessam por tabela (para imprimir posição destacada)
INTEREST = {
    "SA1": ["A1_FILIAL","A1_COD","A1_LOJA","A1_NOME","A1_NREDUZ","A1_END","A1_BAIRRO","A1_MUN","A1_EST","A1_CEP","A1_COD_MUN","A1_TEL","A1_EMAIL","A1_CGC","A1_VEND","A1_USTATUS","A1_MSBLQL","A1_RISCO","A1_SATIV1","A1_CONTATO","A1_LC","A1_DTULTNF"],
    "SB1": ["B1_FILIAL","B1_COD","B1_DESC","B1_TIPO","B1_GRUPO","B1_UM","B1_PRV1","B1_LOCAL","B1_MSBLQL","B1_DTREFP1"],
    "SBM": ["BM_FILIAL","BM_GRUPO","BM_DESC","BM_PRODUTO"],
    "SC6": ["C6_FILIAL","C6_ITEM","C6_PRODUTO","C6_DESCRI","C6_QTDVEN","C6_PRCVEN","C6_VALOR","C6_NUM","C6_CLI","C6_LOJA","C6_TES","C6_PRUNIT","C6_ENTREG","C6_NOTA","C6_SERIE","C6_GRADE","C6_QTDENT"],
    "SD2": ["D2_FILIAL","D2_ITEM","D2_COD","D2_QUANT","D2_PRCVEN","D2_TOTAL","D2_PRUNIT","D2_TES","D2_CF","D2_DOC","D2_SERIE","D2_CLIENTE","D2_LOJA","D2_EMISSAO","D2_GRUPO","D2_VEND1","D2_PEDIDO","D2_ITEMPV","D2_CUSTO1","D2_DESCON","D2_LOCAL"],
    "SF4": ["F4_FILIAL","F4_CODIGO","F4_TIPO","F4_TEXTO","F4_DUPLIC","F4_ESTOQUE","F4_CF","F4_DESCRI"],
    "SX5": ["X5_FILIAL","X5_TABELA","X5_CHAVE","X5_DESCRI","X5_DESCSPA","X5_DESCENG"],
    "SZ1": [],
}


def load_dict():
    tables = {}
    with open(DICT_PATH, "r", encoding="latin-1", newline="") as fh:
        reader = csv.reader(fh, delimiter=";", quotechar='"')
        for row in reader:
            if len(row) < 6:
                continue
            tbl = row[0].strip()
            ordem = row[1].strip()
            field = row[2].strip()
            ftype = row[3].strip()
            try:
                size = row[4].strip()
                dec = row[5].strip()
            except IndexError:
                size = dec = ""
            if not tbl or not field:
                continue
            tables.setdefault(tbl, []).append({
                "ordem": ordem, "field": field, "type": ftype,
                "size": size, "dec": dec,
            })
    return tables


def ordem_key(o):
    # X3_ORDEM é 2 chars: '0'-'9' < 'A'-'Z'. Ordenação por valor de char.
    return tuple(ord(c) for c in o.ljust(2))


def first_csv_cols(table):
    fname = CSV_FILES.get(table)
    if not fname:
        return None
    path = os.path.join(ROOT, fname)
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="latin-1", newline="") as fh:
        line = fh.readline()
    # split respeitando aspas
    reader = csv.reader([line], delimiter=";", quotechar='"')
    return next(reader)


def main():
    tables = load_dict()
    targets = ["SA1","SB1","SBM","SC6","SD2","SF4","SX5","SZ1","CC2","SA3","SC5","SF2","ZA7"]
    for t in targets:
        fields = tables.get(t)
        print("=" * 70)
        if not fields:
            print(f"{t}: NÃO encontrado no dicionário SX3")
            continue
        fields = sorted(fields, key=lambda f: ordem_key(f["ordem"]))
        csvcols = first_csv_cols(t)
        ncsv = len(csvcols) if csvcols else "?"
        print(f"{t}: {len(fields)} campos no SX3 | colunas na 1a linha do CSV: {ncsv}")
        interest = set(INTEREST.get(t, []))
        for i, f in enumerate(fields, start=1):
            mark = ""
            if f["field"] in interest:
                sample = csvcols[i - 1] if csvcols and i - 1 < len(csvcols) else ""
                mark = f"   <<< pos={i}  amostra={sample!r}"
            if interest and not mark:
                continue
            print(f"  [{i:3}] {f['ordem']:>2} {f['field']:<12} {f['type']} {f['size']}.{f['dec']}{mark}")
        # tail check: últimas 4 colunas reais
        if csvcols:
            print(f"  ...últimas colunas CSV: {csvcols[-4:]}")


if __name__ == "__main__":
    main()
