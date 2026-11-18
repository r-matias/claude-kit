Interface: vale para todo arquivo de tela, componente ou estilo.
1. Reuso antes de criar. Procure com Grep/Glob o componente, o token e a tela mais parecida do projeto e siga o padrão dela. Componente ou estilo novo só quando nada existente serve.
2. Token, nunca valor solto. Cor, espaçamento, raio, sombra, fonte e ponto de quebra vêm do tema ou dos tokens do projeto. Projeto sem tema: defina os tokens num lugar só antes da primeira tela (espaçamento em múltiplos de 4, de 4 a 6 tamanhos de fonte, uma cor de ação, neutros e cores de estado) e use só eles.
3. Uma ação principal por tela, visível sem rolar, e um título que diz onde a pessoa está. Ação secundária tem menos peso visual.
4. Estados. Todo dado que vem de fora tem tela para vazio, carregando e erro. Toda ação dá retorno: carregando, sucesso e erro junto do campo ou do botão. Ação destrutiva pede confirmação.
5. Tela pequena primeiro. Comece em 320px de largura e amplie. Contêiner sem largura fixa em px, página sem rolagem horizontal em nenhuma largura, tabela e grade com versão para celular.
6. Acessível (WCAG 2.2 AA). Elemento nativo (button, a, input, label) antes de div com clique; todo controle com nome acessível e todo campo com rótulo visível; foco visível; contraste de texto de 4.5:1 (3:1 para texto grande); alvo de toque de 24×24px no mínimo e 44px quando o uso é por toque; imagem informativa com texto alternativo; nada depende só de cor.
7. Hierarquia e ritmo. No máximo duas famílias de fonte, alinhamento numa grade, espaço em branco para separar grupos em vez de caixa em volta de tudo, um raio e uma sombra por tipo de superfície.
8. Biblioteca de componentes. Use o componente dela como a documentação da versão instalada manda: confira a versão no manifesto e consulte a documentação antes de usar um componente que o projeto ainda não usa. Não reimplemente o que ela já entrega.
9. Movimento curto e com motivo (150 a 300ms), respeitando prefers-reduced-motion.
10. Texto da interface curto, no idioma do produto, com verbo no botão e mensagem de erro que diz como resolver.
