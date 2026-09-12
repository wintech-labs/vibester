import 'package:flutter/material.dart';

class AppColors extends ThemeExtension<AppColors> {
  final Color navy;
  final Color ambar;
  final Color grey;
  final Color darkGrey;
  final Color brasa;
  final Color noturno;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color textDisabled;
  final Color border;
  final Color error;

  const AppColors({
    required this.navy,
    required this.ambar,
    required this.grey,
    required this.darkGrey,
    required this.brasa,
    required this.noturno,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.textDisabled,
    required this.border,
    required this.error,
  });

  /// Gradiente da marca, derivado de `ambar` e `brasa` do tema atual.
  ///
  /// Use em `BoxDecoration.gradient` para fundos, cards e botões; para texto
  /// e ícones use `GradientMask` (theme_extensions.dart).
  LinearGradient get gradient => LinearGradient(colors: [ambar, brasa]);

  // -------------------------------------------------------------------
  // Superfícies derivadas
  //
  // A paleta do Vibester (navy / ambar / brasa / noturno / darkGrey / grey) é
  // patrimônio da marca: os *papéis* não mudam entre temas, só a matiz. O que
  // falta pra construir hierarquia de
  // profundidade não é cor nova, e sim *camada*: as superfícies abaixo são
  // todas derivadas por opacidade/mistura dos tokens existentes, então o app
  // continua cromaticamente idêntico a si mesmo.
  // -------------------------------------------------------------------

  /// Fundo de tela. Alias semântico de [noturno].
  Color get background => noturno;

  /// Primeira camada acima do fundo (bloco, célula de lista, campo). Um
  /// [navy] muito diluído sobre o fundo — dá relevo sem virar "card cinza".
  Color get surface => Color.alphaBlend(navy.withValues(alpha: 0.55), noturno);

  /// Segunda camada (sheet, painel sobreposto, dock).
  Color get surfaceRaised =>
      Color.alphaBlend(navy.withValues(alpha: 0.88), noturno);

  /// Traço estrutural discreto — separadores e contornos de superfície, onde
  /// [border] (white38) seria alto demais.
  Color get hairline => grey.withValues(alpha: 0.18);

  /// Traço de contorno visível, usado como elemento gráfico (moldura de
  /// poster, chip selecionado).
  Color get outline => grey.withValues(alpha: 0.38);

  /// Véu sobre imagem para garantir contraste de texto sobreposto. Sempre
  /// preto real: escurecer com [noturno] tingiria a foto de roxo.
  Color get scrim => const Color(0xFF000000);

  /// Gradiente de leitura para texto sobre foto (transparente → escuro).
  /// Usado por todo card com metadado sobreposto.
  LinearGradient get photoScrim => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: const [0.0, 0.45, 1.0],
    colors: [
      scrim.withValues(alpha: 0.0),
      scrim.withValues(alpha: 0.45),
      scrim.withValues(alpha: 0.92),
    ],
  );

  /// Véu de cor de marca sobre a base de uma foto, aplicado **por cima** do
  /// [photoScrim].
  ///
  /// O scrim sozinho é preto: garante contraste, mas deixa todo card com a
  /// mesma base cinza-escura, seja qual for a foto. Este véu devolve a
  /// temperatura da marca à parte inferior do cartaz — é o mesmo efeito de
  /// tinta atravessando papel de lambe-lambe — sem tocar no topo da imagem,
  /// onde a foto ainda precisa aparecer limpa.
  ///
  /// Vem depois do scrim de propósito: a legibilidade do texto continua sendo
  /// garantida pelo preto, e a cor entra como camada, não como substituta.
  LinearGradient photoTint(Color accent) => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: const [0.35, 1.0],
    colors: [accent.withValues(alpha: 0.0), accent.withValues(alpha: 0.30)],
  );

  /// Cor de "ao vivo / acontecendo agora". É [brasa] — a única cor quente
  /// urgente da paleta — isolada num nome semântico pra não ser usada como
  /// decoração genérica.
  Color get live => brasa;

  /// Tinta escura da marca, fixa nos dois temas.
  ///
  /// É o [noturno] do tema escuro usado como *cor de texto*, não como fundo:
  /// por isso é constante e não acompanha o tema — ela existe para ficar sobre
  /// preenchimentos de marca, que também não mudam entre temas.
  static const Color ink = Color(0xFF0C0910);

  /// Cor legível de texto/ícone sobre um preenchimento sólido.
  ///
  /// Escolhe entre [ink] e branco pela razão de contraste real, em vez de
  /// assumir branco. Isso não é preciosismo: branco sobre `ambar` (#F88806)
  /// dá **2,47:1**, abaixo até do piso de 3:1 da WCAG para texto grande — era
  /// o rótulo de todo botão principal, chip selecionado e tag de marca do app.
  /// Com [ink] a mesma combinação vai a 8:1, e de quebra fica mais parecida
  /// com tinta preta sobre papel laranja, que é a direção de cartaz do
  /// produto.
  ///
  /// Em fundos escuros (o vermelho de erro do tema claro, por exemplo) a conta
  /// devolve branco sozinha — nenhuma tela precisa decidir isso na mão.
  Color onFill(Color background) {
    final luminancia = background.computeLuminance();
    final contrasteComBranco = 1.05 / (luminancia + 0.05);
    final contrasteComTinta =
        (luminancia + 0.05) / (ink.computeLuminance() + 0.05);

    return contrasteComTinta >= contrasteComBranco ? ink : Colors.white;
  }

  /// Atalho para o caso mais comum: texto sobre [ambar].
  Color get onAmbar => onFill(ambar);

  /// Texto sobre [brasa].
  Color get onBrasa => onFill(brasa);

  static const AppColors dark = AppColors(
    navy: Color(0xFF17112A),
    ambar: Color(0xFFF88806),
    grey: Color(0xFF94A3B8),
    darkGrey: Color(0xFF0E0E0E),
    brasa: Color(0xFFFF4D1C),
    noturno: Color(0xFF0C0910),
    textPrimary: Colors.white,
    textSecondary: Colors.white70,
    textMuted: Colors.white54,
    textDisabled: Colors.white38,
    border: Colors.white38,
    error: Color(0xFFFF5252),
  );

  /// Tema claro — espelho frio da paleta escura.
  ///
  /// O par `ambar`/`brasa` não se distingue por profundidade: no tema escuro
  /// eles têm claridade 50 e 55 e apenas 1,35:1 de contraste entre si. O que
  /// separa os dois é **matiz** — 19°, de laranja-amarelo a vermelho. Este
  /// tema reproduz essa relação, não a aparência.
  ///
  /// A distância virou 49°, e isso é de propósito: a percepção de matiz é
  /// comprimida no azul. 19° na faixa quente atravessa duas cores nomeáveis;
  /// 19° na faixa fria é indistinguível. 49° entre ciano e índigo devolve a
  /// mesma separação que o par original tem a olho nu, e a razão de claridade
  /// entre eles fica em 1,41:1 — praticamente o 1,35:1 do par quente.
  ///
  /// A posição em relação ao papel, essa sim, inverte: no escuro o acento é
  /// mais claro que o fundo, aqui é mais escuro. Ambos os tokens são cor de
  /// *texto* em dezenas de telas, não só preenchimento, então os dois ficam
  /// acima de 4,5:1 sobre [noturno] — é esse piso que impede um azul mais
  /// claro que estes.
  ///
  /// [error] é a única cor quente que sobra, de propósito: erro não espelha.
  static const AppColors light = AppColors(
    // Azul claríssimo — fonte de `surface` (#E1EAF5) e `surfaceRaised`
    // (#D4E0F1). Matiz 215°, entre os dois acentos, para não puxar as
    // camadas nem pro ciano nem pro índigo.
    navy: Color(0xFFCFDDF0),
    // 195° — ciano-azur. O lado luminoso do par: 4,8:1 sobre o papel, logo
    // acima do piso de texto. Nenhum azul mais claro que este serve como
    // `ambar`, porque `ambar` é cor de texto em dezenas de telas.
    ambar: Color.fromARGB(255, 77, 190, 255),
    // Escurecido de #94A3B8 mantendo a matiz: `hairline` deriva daqui por
    // opacidade e, com o cinza claro, o separador sumia sobre `surface`.
    grey: Color(0xFF64748B),
    darkGrey: Color(0xFFF0EDF5),
    // 244° — índigo. 49° de distância do `ambar`: é o que dá ao [gradient] da
    // marca uma viagem de matiz de verdade, em vez de um degradê de brilho
    // entre dois azuis parecidos.
    brasa: Color(0xFF4A3FD6),
    // Branco com pigmento azul, como o noturno escuro e um preto com pigmento
    // roxo. Papel branco puro tira a temperatura da tela inteira.
    noturno: Color(0xFFF7F9FC),
    textPrimary: Color(0xFF0B1B33),
    textSecondary: Color(0xFF33455C),
    textMuted: Color(0xFF5A6B82),
    textDisabled: Color(0xFF8D9BAE),
    border: Color(0xFFC3D2E6),
    error: Color(0xFFC62828),
  );

  /// Alias mantido para não quebrar código legado que ainda referencie o
  /// nome antigo; equivale ao tema escuro (paleta original do app).
  static const AppColors defaultColors = dark;

  @override
  AppColors copyWith({
    Color? navy,
    Color? ambar,
    Color? grey,
    Color? darkGrey,
    Color? brasa,
    Color? noturno,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? textDisabled,
    Color? border,
    Color? error,
  }) {
    return AppColors(
      navy: navy ?? this.navy,
      ambar: ambar ?? this.ambar,
      grey: grey ?? this.grey,
      darkGrey: darkGrey ?? this.darkGrey,
      brasa: brasa ?? this.brasa,
      noturno: noturno ?? this.noturno,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      textDisabled: textDisabled ?? this.textDisabled,
      border: border ?? this.border,
      error: error ?? this.error,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      navy: Color.lerp(navy, other.navy, t)!,
      ambar: Color.lerp(ambar, other.ambar, t)!,
      grey: Color.lerp(grey, other.grey, t)!,
      darkGrey: Color.lerp(darkGrey, other.darkGrey, t)!,
      brasa: Color.lerp(brasa, other.brasa, t)!,
      noturno: Color.lerp(noturno, other.noturno, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      border: Color.lerp(border, other.border, t)!,
      error: Color.lerp(error, other.error, t)!,
    );
  }
}