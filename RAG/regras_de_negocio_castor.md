# Regras de Negócio — Agente Castor

Este documento consolida as regras de negócio que o agente Castor deve respeitar. É indexado pelo RAG e também referenciado pelo system prompt do agente principal.

## 1. Fonte de dados

Toda a operação do agente lê de **tabelas espelho/agregadas no Postgres** populadas via upload admin. Os CSVs originais do Protheus ficam armazenados no Google Drive (pasta `DRIVE_FOLDER_ID_SOURCE = 1mFSgsUNhDCAsq73prFtD5b1RyqtXpIUx`) como histórico bruto, e cada upload **substitui o conteúdo preservando o mesmo `file_id`** (Drive nunca sofre `files.delete`).

O workflow `Castor-Source-Manager` expõe:
- `GET  /castor-source-list`    — lista os arquivos canônicos no Drive.
- `GET  /castor-source-status`  — `castor_admin_sources_status()` retorna por tabela: rows_count, last_ingest_at, last_ok, etc.
- `POST /castor-source-replace` — multipart upload. Se o arquivo existe, `files.update` (PATCH) no mesmo `file_id`; senão `files.create`.
- `POST /castor-source-ingest`  — `{ table, file_id }`. Parse streaming + `TRUNCATE + INSERT em lotes` em transação no Postgres, registra em `castor_ingest_log`, invalida cache do Panel-API.

O workflow `Castor-Panel-API` (endpoint `GET /castor-panel-snapshot`) faz **1 query SQL** agregando `castor_src_*`, `castor_metrics_*`, `castor_visita_feedback`, `castor_cnpj_cache` e devolve um snapshot único (cache 5 min em `workflowStaticData`). Não há parse de CSV em runtime.

Não há integração Protheus em tempo real. A frequência das atualizações é decisão da empresa (re-upload via tela admin).

| Arquivo no Drive | Origem Protheus | Tabela Postgres | Conteúdo | Usado em |
|---|---|---|---|---|
| `SA1010.csv` | SA1010 | `castor_src_sa1010` | Cadastro de clientes (CNPJ, endereço, vendedor `a1_vend`, status `a1_ustatus`) | snapshot.clientes |
| `SA3010.csv` | SA3010 | `castor_src_sa3010` | Cadastro de vendedores (`a3_cod`, `a3_nome`) | join `vendedor_nome` |
| `SF2010.csv` | SF2010 | `castor_metrics_sf2010` (agregado) | NF cabeçalho → agregado em 365d: `faturamento_12m`, `pedidos_12m`, `ticket_medio_12m`, `ultima_nota` | snapshot.clientes |
| `SC5010.csv` | SC5010 | `castor_metrics_sc5010` (agregado) | Pedidos cabeçalho → agregado: `ultimo_pedido` / `dias_sem_pedido` | snapshot.clientes |
| `ZA7010.csv` | ZA7010 | `castor_src_za7010` | TMKT / base de leads. Filtrado pelos CNPJs que **não** estão em SA1010 | snapshot.leads |
| `CC2010.csv` | CC2010 | `castor_src_cc2010` | Municípios IBGE com lat/lng | snapshot.municipios + roteirização |
| `SA1010.csv` (mestre) | SA1010 | `castor_src_sa1010` | Cadastro mestre de clientes (extração custom: 28 colunas, `A1_CODCLI`=`a1_cod`+`a1_loja`, flags `ATIVO`/`INATIVO`, sem `A1_USTATUS`, `A1_ULTCOM`, `A1_SATIV1`=ramo) | `castor_cliente_enriquecido` |
| `SB1010.csv` | SB1010 | `castor_src_sb1010` | Cadastro mestre de produtos (`b1_cod`, `b1_desc`, `b1_grupo`) | mix/ranking de produtos |
| `SBM010.csv` | SBM010 | `castor_src_sbm010` | Descrição dos grupos de produto (`bm_grupo`→`bm_desc`) | ranking de grupos |
| `SD2010.csv` (ouro) | SD2010 | `castor_src_sd2010` | **Itens de NF de saída** — base de faturamento por produto/grupo/mês. CFOP (`d2_cf`) classifica venda × bonificação × devolução | `castor_metrics_produto*`, `castor_metrics_mensal`, `castor_metrics_venda_cliente` |
| `SF4010.csv` | SF4010 | `castor_src_sf4010` | TES → CFOP (regra fiscal por tipo de operação) | apoio à classificação CFOP |
| `SX5010.csv` | SX5010 | `castor_src_sx5010` | Tabela genérica `T3` = ramo de atividade (`A1_SATIV1`→descrição) | `ramo_desc` em `castor_cliente_enriquecido` |
| `SZ1010.csv` | SZ1010 | `castor_src_sz1010` | Histórico de alteração de status/risco do cliente | `castor_client_status_history()` |

Os CSVs `SC6010` (itens de pedido, ~340 MB — coberto pelo SD2010) e `FATOTEMPO` ficam apenas no Drive como histórico bruto.

## 2. Definição de "cliente inativo elegível para reativação"

**Critério único:** `castor_src_sa1010.a1_ustatus = '2'` (no snapshot: `cliente.a1_ustatus === '2'`).

Não há janela de tempo adicional (ex.: "sem pedido há N dias"). Confiamos 100% no que o ERP marca em `a1_ustatus`. Se o status muda para outro valor (via novo upload de SA1010), o cliente sai automaticamente da fila de reativação.

O subflow `[Castor] Sub-fluxo_ Get Reactivation List` aplica esse filtro sobre `snapshot.clientes` e ainda exclui clientes com `last_feedback.outcome = 'convertido'`.

## 3. Definição de "lead novo"

**Critério:** registro em `ZA7010` cujo CNPJ (apenas dígitos) **não** aparece em `SA1010`. Lead = empresa em prospecção que ainda não virou cliente.

A filtragem é feita pelo `Castor-Panel-API` ao construir `snapshot.leads`.

## 4. Feedback de visita

Toda visita ao cliente gera um registro em `castor_visita_feedback` via RPC `castor_register_visit_feedback`.

Regras de `next_contact_at`:

| outcome | Cálculo |
|---|---|
| `negativo` | `visited_at + COALESCE(custom_days, 20)` dias |
| `voltar_depois` | `visited_at + COALESCE(custom_days, 20)` dias (vendedor pode passar `custom_days` quando o cliente sugeriu data) |
| `convertido` | `next_contact_at = NULL`. Cliente só reentra na fila se `a1_ustatus` voltar a `'2'` |

Vendedor sempre pode sobrescrever os 20 dias default passando `custom_days` no payload.

## 5. Classificação de porte

Há **duas** fontes de porte, com precedência:

1. **Porte efetivo (preferencial)** — calculado pelo ingest do SF2010 a partir do faturamento real
   nos últimos 365 dias (`SF2010.f2_valbrut` agregado por `cliente_codigo = a1_cod || a1_loja`),
   armazenado em `castor_metrics_sf2010.ticket_medio_12m`:

   | Ticket médio 12m | Porte |
   |---|---|
   | < R$ 3.000 | `pequeno` |
   | R$ 3.000 – 10.000 | `medio` |
   | > R$ 10.000 | `grande` |

   Cliente sem histórico recai automaticamente no porte da Receita Federal.
   No snapshot, o campo é exposto como `porte_efetivo` com `porte_origem` em `historico | receita_federal | sem_dados`.

2. **Porte Receita Federal (fallback)** — subflow `[Castor] Sub-fluxo_ Consultar CNPJ`:

1. Consulta cache `castor_cnpj_cache` (TTL 30 dias).
2. Se expirado/ausente: chama BrasilAPI (`https://brasilapi.com.br/api/cnpj/v1/{cnpj}`); fallback ReceitaWS em caso de erro.
3. Armazena `payload` completo + `fetched_at` + `expires_at = fetched_at + 30 days`.

Mapeamento Receita Federal → Castor:

| RF `porte` | Castor |
|---|---|
| `MEI`, `ME` | `pequeno` |
| `EPP` | `medio` |
| `DEMAIS` / qualquer outro | `grande` |

Workflow `Castor-CNPJ-Refresh.json` (cron semanal) renova entradas expiradas em lote.

## 5.1. Fila de reativação priorizada

O subflow `[Castor] Sub-fluxo_ Get Reactivation List` (e o front, em `RoutesPanel.deriveReactivation`) calcula em memória, sobre `snapshot.clientes`:

- `priority_rank` — posição na fila. Ordem: **faturamento dos últimos 12 meses (DESC)**, depois `pedidos_12m`, depois `cliente_codigo`. `#1` = topo da fila.
- `days_until_recall` — `next_contact_at - hoje`. `null` ou `≤0` significa elegível agora.
- `elegivel_agora` — boolean derivado.
- `porte_efetivo`, `faturamento_12m`, `ticket_medio_12m`, `ultima_visita`, `proximo_contato`.

A aba **Roteiros & Clientes** do front consome esses campos para exibir badges
"#1", "faltam 12d", "elegível agora". Não há mais views/RPCs Postgres para essa fila — tudo é derivado do snapshot Drive-only.

## 6. Roteirização

Endpoint `POST /castor-panel-route` (e o subflow `[Castor] Sub-fluxo_ Route Order`):

- Resolve coordenadas usando `snapshot.municipios` (vindo de `CC2010`) por `(a1_mun, a1_est)`. Clientes sem coordenada são devolvidos em `skipped[]`.
- Nearest-neighbor greedy em JS a partir da origem (depósito).
- Distance via Haversine.
- Retorna `stops[]` reordenados (com `leg_km` e `cum_km`), `total_km` e `maps_url` (Google Maps).
- Loga em `castor_route_log` (uma linha por chamada) para auditoria.

Constantes:
- `CASTOR_DEPOT_ADDRESS = 'R. Álvares Cabral, 1049 - Serraria, Diadema - SP, 09980-160'`
- `CASTOR_DEPOT_LAT ≈ -23.6884`
- `CASTOR_DEPOT_LNG ≈ -46.6178`

O front renderiza um modal com lista numerada + km estimado + link `https://www.google.com/maps/dir/?api=1&origin=...&waypoints=...&destination=...`. Não chamamos nenhuma API de mapas paga.

## 7. Visibilidade por role

- **`admin`**: vê todos os clientes, todos os vendedores, todas as visitas.
- **`vendedor`**: vê apenas registros onde `castor_src_sa1010.a1_vend = (SELECT codigo FROM castor_vendor_user WHERE user_id = auth.uid())`.

Mapeamento `user_id ↔ a3_cod` vive em `castor_vendor_user`. Admin gerencia esse vínculo via UI.

Tools enviam `X-User-Id` e `X-User-Role` como headers; RPCs `SECURITY DEFINER` aplicam o filtro server-side. O front nunca decide visibilidade sozinho.

## 8. Bloco de resposta especializado

O agente principal pode emitir blocos fenced renderizados pelo front:

- ```` ```castor-route ```` — lista roteirizada
- ```` ```castor-client-card ```` — card de cliente com porte/contato/última visita
- ```` ```castor-lead-card ```` — card de lead novo
- ```` ```castor-feedback-form ```` — formulário inline pós-visita

Schemas detalhados ficam no system prompt do `Castor-Agent-IA.json`.

## 9. Camada analítica: produtos, itens e tempo (migration 037)

A partir da ingestão de `SD2010` (itens de NF), `SB1010`/`SBM010` (produtos/grupos),
`SF4010`/`SX5010` (CFOP/ramo) e `SZ1010` (histórico de status), a base ganhou uma
camada analítica **aditiva** (não altera as regras anteriores).

### 9.1. Faturamento de VENDA × bonificação × devolução (CFOP)

`SD2010` mistura operações. A função `castor_cfop_class(d2_cf)` classifica cada item:

- **venda** — CFOP `5xx`/`6xx` de venda (510x, 540x, 511x, 512x…). **Única receita real.**
- **bonificação** — CFOP `59x`/`69x` (brinde/amostra). **NÃO é receita.**
- **devolução** — CFOP `1x`/`2x` (entrada) + casos específicos. Reduz/contesta venda.
- **transferência** — 515x/540x entre filiais.

Toda métrica de produto/grupo/mês considera **apenas `venda`**. Ao falar de faturamento,
o agente nunca soma bonificação como receita; se perguntado, explica que são separados.

### 9.2. Agregados (atualizados no ingest de SD2010)

- `castor_metrics_produto_cliente` — produto × cliente (qtd, valor, nº notas, 1ª/última compra).
- `castor_metrics_produto` — ranking global de produtos.
- `castor_metrics_grupo` — ranking global de grupos.
- `castor_metrics_mensal` — faturamento de venda por cliente × mês (`YYYY-MM`).
- `castor_metrics_venda_cliente` — por cliente: `fat_venda_12m`, `fat_venda_alltime`,
  `fat_bonificacao`, `fat_devolucao`, `ultima_venda`.

Recalculados por `castor_refresh_metrics_sd2()` após cada upload de SD2010.

### 9.3. SA1010 como cadastro mestre + enriquecimento

`castor_src_sa1010` guarda o cadastro custom (28 colunas). `castor_refresh_sa1010_derived()`
deriva `cliente_codigo` (=`a1_cod`+`a1_loja`, loja normalizada com `lpad(...,2,'0')`) e os
booleans `a1_ativo`/`a1_inativo` a partir das flags `ATIVO`/`INATIVO`. A view
`castor_cliente_enriquecido` faz LEFT JOIN de SA1010 + venda + ramo (`SX5` tabela `T3`)
sobre `castor_client_metrics_v2`, expondo `nome`, `status_sa1010`, `ramo_desc`,
`elegivel_reativacao` (= `a1_inativo`) e os campos de venda.

> Observação: a fila de reativação **operacional** continua usando `status_real`/`a1_ustatus`
> do `castor_client_metrics_v2` (seção 2). O flag `a1_inativo` do SA1010 é um sinal
> complementar exposto via `castor_cliente_enriquecido`, não substitui a regra existente.

### 9.4. RPCs e tools do agente

Todas `SECURITY DEFINER`, escopadas (admin = global; vendedor = carteira):

| RPC | Tool do agente | Uso |
|---|---|---|
| `castor_product_mix(user, cliente, limit)` | `get_product_mix` | o que UM cliente compra (produtos + grupos) |
| `castor_top_products(user, limit, grupo?)` | `get_top_products` | ranking de produtos mais vendidos |
| `castor_top_groups(user, limit)` | `get_top_groups` | ranking de grupos de produto |
| `castor_monthly_trend(user, cliente?, months)` | `get_sales_trend` | faturamento mês a mês (série) |
| `castor_crosssell(user, cliente, limit)` | `get_crosssell_suggestions` | grupos que o ramo compra e o cliente não |
| `castor_client_status_history(user, cliente, limit)` | `get_client_status_history` | histórico de status/risco (SZ1010) |

O Panel-API expõe `top_products`, `top_groups` e `sales_trend` no snapshot, consumidos
pela aba **Produtos** do front (rankings + gráfico de tendência de faturamento de venda).
