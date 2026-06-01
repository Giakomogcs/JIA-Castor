// Injeta no systemMessage do RAG AI Agent a documentação das 6 novas tools de produtos/itens/tendência.
const fs = require('fs');
const path = require('path');
const FILE = path.resolve(__dirname, '..', 'castor-agent', 'workspaces', 'Castor-Agent-IA.json');
const wf = JSON.parse(fs.readFileSync(FILE, 'utf8'));

const agent = wf.nodes.find(n => n.name === 'RAG AI Agent');
if (!agent) throw new Error('RAG AI Agent não encontrado');
let sm = agent.parameters.options.systemMessage;

const BLOCK = `
=============================================
## FERRAMENTAS NOVAS — PRODUTOS, MIX & TENDÊNCIA (Notas Fiscais / Protheus)
Base: itens de NOTA FISCAL de saída (SD2010). Faturamento aqui é SEMPRE de VENDA real — bonificação (CFOP 59x/69x) e devolução (CFOP 1x/2x) já são EXCLUÍDAS. Não some bonificação como receita.

15. **get_product_mix** — o que UM cliente compra (top produtos + grupos). USE WHEN "o que o cliente X compra", "mix do cliente", "principais itens dele". Precisa de cliente_codigo (8 dígitos = A1_COD+A1_LOJA).
16. **get_top_products** — ranking de produtos mais vendidos (carteira do vendedor; admin = global). Filtro opcional por grupo. USE WHEN "produtos que mais vendem", "top itens".
17. **get_top_groups** — ranking de GRUPOS de produto. USE WHEN "categorias mais fortes", "ranking por grupo".
18. **get_sales_trend** — faturamento mês a mês (série temporal). Com cliente_codigo = série do cliente; sem = total/carteira. USE WHEN "evolução", "está caindo ou crescendo", "tendência mensal". Compare meses para dizer se sobe/cai; não invente sazonalidade sem dado.
19. **get_crosssell_suggestions** — grupos que clientes do MESMO RAMO compram e este NÃO. USE WHEN "o que mais posso oferecer", "sugestão de cross-sell", "oportunidades". Apresente como SUGESTÃO, nunca como certeza.
20. **get_client_status_history** — histórico de mudança de status/risco do cliente (SZ1010). USE WHEN "ele já foi bloqueado", "como variou o risco/status".

REGRA DE OURO PRODUTOS: nunca invente nome/código de produto, grupo ou valor. Se a tool voltar vazia, diga que não há histórico de venda registrado para o filtro. Faturamento de produto = só VENDA (CFOP de venda); se o usuário perguntar de bonificação/devolução, explique que são separados e não entram na receita.

`;

const ANCHOR = '\nREGRA DE PRIVACIDADE:';
if (sm.includes('**get_product_mix**')) {
  console.log('Bloco já presente — nada a fazer.');
} else if (sm.includes(ANCHOR)) {
  sm = sm.replace(ANCHOR, BLOCK + ANCHOR.slice(1));
  agent.parameters.options.systemMessage = sm;
  const out = JSON.stringify(wf, null, 2);
  JSON.parse(out);
  fs.writeFileSync(FILE, out + '\n', 'utf8');
  console.log('Bloco injetado antes de REGRA DE PRIVACIDADE. systemMessage len:', sm.length);
} else {
  throw new Error('Âncora REGRA DE PRIVACIDADE não encontrada no systemMessage');
}
