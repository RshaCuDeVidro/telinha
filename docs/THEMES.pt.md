# Temas do telinha

<sub>[🇺🇸 English](THEMES.md) · [🇧🇷 Português](THEMES.pt.md)</sub>

Cada tema é um arquivo `.kdl` (o formato [KDL](https://kdl.dev): nós, valores
e blocos entre chaves). Os que vêm com o telinha estão em
[`src/assets/temas/`](../src/assets/temas); os seus ficam na pasta `temas` da
configuração:

| Sistema | Pasta |
|---|---|
| Windows | `%APPDATA%\telinha\temas` |
| Linux | `~/.config/telinha/temas` |

O jeito mais fácil: **Configurações → Aparência → Criar o meu a partir deste**.
O telinha escreve o tema que você está usando, com todas as cores, num arquivo
novo (`meu-pwnd.kdl`, por exemplo), já passa a usar ele e abre a pasta. Mude o
que quiser e salve: **o telinha aplica sozinho** assim que você volta pra janela
dele (ou em até 2 segundos com a página Aparência aberta). Um arquivo com o
mesmo id de um tema embutido troca o embutido.

Se algo estiver errado, a página Aparência mostra o arquivo, a linha e o que
não deu pra entender.

## Exemplo comentado

```kdl
// tudo depois de // é comentário; /- desliga o próximo nó
theme "meu-tema" name="Meu tema" name-en="My theme" author="eu" \
    description="Aparece quando o mouse passa no cartão do tema."

colors {
    // as sete de base: o resto da paleta sai delas
    bg        "#0B1218"   // o fundo mais escuro (tela inicial, atrás de tudo)
    panel     "#101B23"   // painéis da lateral
    accent    "#34D3B4"   // destaque: botões, seleção, bordas acesas
    text      "#DDEBF0"
    success   "#34D399"   // verde (ligado, no ar)
    danger    "#F87171"   // vermelho (sair, parar, erro)
    accent-2  "#8B7CFF"   // segunda cor: degradês e o brilho neon

    // dá pra trocar qualquer outra parte (veja a lista abaixo)
    hover     "alpha(@accent, 0.09)"   // @nome = outra cor deste bloco
    selected  "mix(@panel, @accent-2, 0.3)"
    border    "alpha(@accent, 0.12)"
}

// fundo da tela inicial (4 cantos: ↖ ↗ ↘ ↙) e o desenho parado do palco
background gradient="#0B1218 #0F2A2A #0B1218 #17123A" pattern=dots \
    pattern-color="alpha(#34D3B4, 0.05)" pattern-size=24

// texto, títulos e números/código; size = tamanho base da letra
fonts ui="Atkinson Hyperlegible" heading="Fira Code" mono="Fira Code" size=15

metrics radius=10 border=1   // cantos (px) e espessura das bordas
effects glow=0.6              // brilho neon: 0 desliga, 1 é forte
```

## Cores

Formatos: `"#rgb"`, `"#rrggbb"`, `"#rrggbbaa"`, `"rgb(10, 20, 30)"`,
`"rgba(10, 20, 30, 0.5)"`, `"white"`, `"black"`, `"transparent"`, e as funções:

| Função | O que faz |
|---|---|
| `alpha(cor, a)` | a mesma cor com transparência `a` (0 a 1, ou `40%`) |
| `mix(a, b, t)` | mistura: `t` = 0 dá `a`, 1 dá `b` |
| `lighten(cor, t)` | clareia (mistura com branco) |
| `darken(cor, t)` | escurece (mistura com preto) |
| `@nome` | outra cor do mesmo bloco `colors` |

Todas as chaves que o bloco `colors` aceita:

| Chave | Onde aparece |
|---|---|
| `bg`, `panel`, `surface`, `elevated`, `float`, `input`, `chat-input` | fundos: tela inicial, painéis, palco, cartões e a barra de controles, dicas e menus, campos |
| `text`, `heading`, `muted`, `faint` | texto, títulos, texto secundário e o mais apagado |
| `accent`, `accent-hover`, `accent-active`, `accent-2` | destaque e suas variações; a segunda cor dos degradês |
| `success`, `success-hover`, `success-active` | verde |
| `danger`, `danger-hover`, `danger-active`, `live`, `leave` | vermelho, o "ao vivo" e o fundo do sair |
| `warning` | amarelo (avisos) |
| `button`, `button-hover`, `button-active` | botões secundários |
| `hover`, `selected`, `border`, `check`, `scroll`, `scroll-hover`, `shadow`, `overlay` | mouse em cima, seleção, contornos, marcas, barra de rolagem, sombras |

## Fontes

`ui` (o texto), `heading` (títulos) e `mono` (números e código) aceitam:

- `"Inter"`: a padrão, limpa.
- `"Atkinson Hyperlegible"`: feita pra baixa visão (letras parecidas como I, l,
  1, O e 0 não se confundem). A mais fácil de ler.
- `"Fira Code"`: monoespaçada, cara de terminal.

Quem acha a fonte de um tema difícil de ler pode trocar só pra si em
**Configurações → Aparência → Fonte do texto**, sem mexer no tema, e aumentar a
letra em **Tamanho da letra**.

## Fundo e efeitos

- `background gradient="..."`: 1, 2 ou 4 cores (cantos ↖ ↗ ↘ ↙).
- `pattern=`: `none`, `grid` (grade), `dots` (pontos) ou `scanlines` (linhas),
  com `pattern-color` e `pattern-size` (8 a 128). É um desenho parado: não gasta
  placa de vídeo.
- `metrics radius=` (cantos em px, 0 = retos) e `border=` (espessura das bordas).
- `effects glow=`: força do brilho neon em volta de botões, telas e avisos.

As animações (botões acendendo, abas deslizando) param sozinhas quando chegam no
lugar: o telinha parado não redesenha. Quem prefere sem movimento liga **Reduzir
movimento** na Aparência (o modo econômico também desliga).
