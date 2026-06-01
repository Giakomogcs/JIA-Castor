# Castor — Regras de Negócio (cópia em-repo)

Esta é uma cópia de [`../../RAG/regras_de_negocio_castor.md`](../../RAG/regras_de_negocio_castor.md) para referência humana dentro do repositório. A fonte canônica indexada pelo RAG é a versão em `RAG/`. Mantenha as duas em sincronia.

Veja o conteúdo completo em `RAG/regras_de_negocio_castor.md`.

## Resumo

- Fonte = arquivos no Drive (pasta source) **+ tabelas espelho/agregadas no Postgres** (`castor_src_sa1010`, `castor_src_sa3010`, `castor_src_za7010`, `castor_src_cc2010`, `castor_metrics_sf2010`, `castor_metrics_sc5010`). Upload pela tela admin substitui o conteúdo no Drive (mesmo `file_id`) e dispara ingest no Postgres (TRUNCATE+INSERT em transação).
- Cliente inativo elegível ⇔ `castor_src_sa1010.a1_ustatus = '2'`.
- Lead novo ⇔ ZA7010 sem CNPJ correspondente em SA1010.
- Feedback de visita: negativo/voltar_depois → +20 dias (ou `custom_days`); convertido → `next_contact_at=NULL`, só volta se status retornar a '2'.
- Porte: MEI/ME=pequeno, EPP=medio, DEMAIS=grande. Cache RF 30 dias. Histórico 12m calculado em `castor_metrics_sf2010` (ticket médio).
- Roteirização: nearest-neighbor Haversine a partir do depósito Diadema/SP (lat -23.6884, lng -46.6178).
- Visibilidade: admin vê tudo; vendedor vê apenas onde `a1_vend = castor_my_vendor_code()`.
- Camada analítica (migration 037): SD2010 (itens de NF) alimenta `castor_metrics_produto*`, `castor_metrics_mensal`, `castor_metrics_venda_cliente`. Faturamento conta só **venda** (CFOP), excluindo bonificação (59x/69x) e devolução (1x/2x) via `castor_cfop_class`. SA1010 vira cadastro mestre (`castor_cliente_enriquecido`). RPCs/tools: `get_product_mix`, `get_top_products`, `get_top_groups`, `get_sales_trend`, `get_crosssell_suggestions`, `get_client_status_history`. Front: aba **Produtos**.
- RAG: pasta dedicada `1Azpe9hHXObz93rio04AVWuUxGOlUlbjj`. Update via `files.update` no mesmo `file_id`. Nunca `files.delete`.
