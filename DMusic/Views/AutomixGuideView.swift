import SwiftUI

/// Tela de guia visual explicando todas as cores da barra de tempo, palco de capas, espectrograma Rekordbox,
/// badges abaixo da barra e todas as curvas de volume, estilos de EQ, filtros e durações disponíveis no Automix.
struct AutomixGuideView: View {
    private let purple = Color(red: 0.72, green: 0.36, blue: 1.0)
    private let coral = Color(red: 1.0, green: 0.34, blue: 0.38)
    private let amber = Color(red: 1.0, green: 0.62, blue: 0.12)
    private let green = Color(red: 0.12, green: 0.88, blue: 0.42)
    private let pink = Color(red: 1.0, green: 0.27, blue: 0.52)
    private let teal = Color(red: 0.15, green: 0.92, blue: 0.85)
    private let gold = Color(red: 0.96, green: 0.78, blue: 0.25)
    private let armedBlue = Color(red: 0.35, green: 0.78, blue: 1.0)

    var body: some View {
        List {
            Section {
                GuideColorRow(
                    color: purple,
                    icon: "arrowtriangle.up.fill",
                    badge: "SYNC",
                    title: "Aumentando BPM (Barra + Halo da Capa)",
                    detail: "O trecho roxo no final da barra de tempo e o halo de luz na borda da capa indicam onde a faixa atual acelera até alcançar o BPM da próxima música."
                )
                GuideColorRow(
                    color: coral,
                    icon: "arrowtriangle.down.fill",
                    badge: "SYNC",
                    title: "Reduzindo BPM (Barra + Halo da Capa)",
                    detail: "O trecho coral no final da barra e o halo na borda da capa mostram onde a faixa atual desacelera até igualar o andamento da próxima."
                )
                GuideColorRow(
                    color: Color.white.opacity(0.45),
                    icon: "equal",
                    badge: "PLATÔ",
                    title: "Cinza Claro na Barra (Novo BPM Travado)",
                    detail: "Indica o trecho final em que a música atual já atingiu e mantém o mesmo BPM da próxima faixa antes da virada."
                )
                GuideColorRow(
                    color: green,
                    icon: "equal",
                    badge: "SYNC",
                    title: "Verde (Sincronizado / Estável)",
                    detail: "Indica que o BPM já parou de variar e está cravado para a entrada da próxima faixa."
                )
                GuideColorRow(
                    color: armedBlue,
                    icon: "waveform",
                    badge: "SYNC 2:45",
                    title: "Transição Armada",
                    detail: "Badge discreto mostrando o minuto exato em que a próxima música vai entrar."
                )
            } header: {
                Text("Barra de Tempo e Sincronização")
            }

            Section {
                GuideColorRow(
                    color: green,
                    icon: "square.split.2x1.fill",
                    badge: "DECK A",
                    title: "Verde (Faixa A — Saindo)",
                    detail: "Durante a transição, a capa da faixa A desliza para a esquerda com filete de luz verde na borda (e ocupa o canal superior A no espectrograma)."
                )
                GuideColorRow(
                    color: amber,
                    icon: "square.split.2x1.fill",
                    badge: "DECK B",
                    title: "Âmbar (Faixa B — Entrando)",
                    detail: "A nova faixa entra pela direita com filete de luz âmbar na borda (e ocupa o canal inferior B no espectrograma) até assumir o centro ao fim do mix."
                )
                GuideColorRow(
                    color: armedBlue,
                    icon: "waveform",
                    badge: "REKORDBOX",
                    title: "Espectrograma RGB & Grade em Compassos",
                    detail: "Ondas em 3 bandas (Vermelho = Graves/Bumbo, Verde = Médios/Voz, Azul = Agudos), marcadores vermelhos de downbeat (tempo 1) e zoom em 4, 6 ou 10 BARS."
                )
            } header: {
                Text("Palco de Capas & Espectrograma (Decks A e B)")
            }

            Section {
                GuideColorRow(
                    color: green,
                    icon: "waveform.path.ecg",
                    badge: "MIX • EQ",
                    title: "Sobreposição + Troca de Graves",
                    detail: "As duas músicas batem juntas com pressão total e trocam os graves (185 Hz) no ponto ideal."
                )
                GuideColorRow(
                    color: purple,
                    icon: "slider.horizontal.3",
                    badge: "MIX • 3B",
                    title: "Transição de 3 Bandas",
                    detail: "Graves, médios/vocais (1 kHz) e agudos (4.2 kHz) alternam progressivamente para evitar choque de vozes ou melodias."
                )
                GuideColorRow(
                    color: pink,
                    icon: "bolt.fill",
                    badge: "MIX • CORTE",
                    title: "Corte Rápido / 1 Compasso",
                    detail: "Transição firme com corte seco na entrada, no centro ou na saída (ex.: quando a próxima faixa já explode no drop)."
                )
                GuideColorRow(
                    color: teal,
                    icon: "sparkles",
                    badge: "MIX • FX / WASH",
                    title: "Filtros DJ / Wash Out",
                    detail: "Varredura de filtro Passa-Alta ou Passa-Baixa, ou cauda de Reverb espacial na saída da faixa anterior."
                )
                GuideColorRow(
                    color: gold,
                    icon: "waveform",
                    badge: "MIX • FADE",
                    title: "Fade Cruzado (Sem Beatmatch)",
                    detail: "Usado automaticamente quando a diferença de BPM é maior que 15%, fazendo uma passagem suave sem forçar o tempo."
                )
            } header: {
                Text("Info de Mix Abaixo da Barra")
            }

            Section {
                ForEach(AutomixDurationChoice.allCases) { item in
                    GuideCatalogRow(title: item.title, detail: durationDescription(item))
                }
            } header: {
                Text("Durações de Mixagem")
            }

            Section {
                ForEach(AutomixVolumeCurve.allCases.filter { $0 != .auto }) { item in
                    GuideCatalogRow(title: item.title, detail: volumeDescription(item))
                }
            } header: {
                Text("Todas as Curvas de Volume")
            }

            Section {
                ForEach(AutomixEQStyle.allCases.filter { $0 != .auto }) { item in
                    GuideCatalogRow(title: item.title, detail: eqDescription(item))
                }
            } header: {
                Text("Todos os Estilos de Equalização (EQ)")
            }

            Section {
                ForEach(AutomixFilterStyle.allCases.filter { $0 != .auto }) { item in
                    GuideCatalogRow(title: item.title, detail: filterDescription(item))
                }
            } header: {
                Text("Todos os Filtros Passa-Alta / Passa-Baixa")
            }
        }
        .navigationTitle("Guia de Cores e Mixagens")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private func durationDescription(_ item: AutomixDurationChoice) -> String {
        switch item {
        case .auto: return "Escolhe 4, 8 ou 16 compassos conforme BPM, fraseado e compatibilidade harmônica."
        case .bars2: return "Virada relâmpago em 2 compassos (~3–4s)."
        case .bars4: return "Virada curta e objetiva em 4 compassos (~6–9s)."
        case .bars8: return "Padrão de pista em 8 compassos (~12–16s)."
        case .bars16: return "Mixagem longa e progressiva em 16 compassos (~24–32s)."
        }
    }

    private func volumeDescription(_ item: AutomixVolumeCurve) -> String {
        switch item {
        case .auto, .overlap: return "Padrão DJ: mantém as duas faixas sobrepostas em volume cheio sem derrubar o som no meio."
        case .smoothCrossfade: return "Crossfade igual-potência clássico e suave do início ao fim."
        case .fadeInFadeOut: return "A música B sobe aos poucos enquanto a A começa a baixar após o meio."
        case .cutInFadeOut: return "Música B entra direto em volume cheio e a A sai em fade."
        case .fadeInCutOut: return "Música B entra gradualmente sobre a A e a A corta seco quando o drop da B assume."
        case .centerCut: return "Troca firme no meio exato da transição."
        case .crossfadeQuickOut: return "B entra rápido e A cai com saída acelerada para evitar choque vocal."
        case .fadeIn1BarCutOut: return "B faz fade-in de 1 compasso e A corta imediatamente."
        case .overlap1BarCutOut: return "Sobreposição de 1 compasso em cheio seguida de corte limpo da faixa A."
        }
    }

    private func eqDescription(_ item: AutomixEQStyle) -> String {
        switch item {
        case .auto, .centerBassSwap: return "B entra sem graves e assume o subgrave/bumbo exatamente na metade da transição."
        case .endBassSwap: return "Mantém o grave da faixa A sustentando até ~82% (ótimo quando B entra só com voz antes do drop)."
        case .startBassSwap: return "Entrega o grave para a faixa B logo no começo da mixagem."
        case .threeBandTransition: return "Troca separada de graves (185 Hz), médios/vocais (1 kHz) e agudos (4.2 kHz)."
        case .quickBassCut: return "Corte rápido do grave da A e entrada imediata do grave da B."
        case .longBassCut: return "Redução longa e progressiva dos graves da faixa A ao longo da janela."
        case .bassFadeOut: return "Retira os graves da A em fade contínuo sem corte brusco."
        }
    }

    private func filterDescription(_ item: AutomixFilterStyle) -> String {
        switch item {
        case .auto: return "Seleciona automaticamente conforme energia, vocais e compatibilidade Camelot."
        case .none: return "Mantém os filtros desativados, atuando só com volume e EQ."
        case .lpOut: return "Fecha o filtro passa-baixa na faixa A, deixando o som dela mais abafado ao sair."
        case .lpIn: return "Abre gradualmente o filtro passa-baixa na faixa B ao entrar."
        case .lpInLpOut: return "Passa-baixa abrindo na B e fechando na A."
        case .lpInHpOut: return "B abre com passa-baixa enquanto A limpa os graves com passa-alta ao sair."
        case .hpOut: return "Varredura passa-alta na A, deixando só agudos/energia antes de sumir."
        case .hpIn: return "B entra filtrada pelo passa-alta e ganha corpo aos poucos."
        case .hpInHpOut: return "Passa-alta na entrada da B e na saída da A para manter a mix limpa."
        case .hpInLpOut: return "B entra por cima com passa-alta enquanto A fecha os agudos com passa-baixa."
        case .partialHpOut: return "Passa-alta parcial na saída da A, preservando presença enquanto B entra."
        case .finalNoiseOut: return "Aplica varredura de filtro com cauda de Reverb espacial (Wash Out) no final da A."
        }
    }
}

private struct GuideColorRow: View {
    let color: Color
    let icon: String
    let badge: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 8.5, weight: .black))
                    Text(badge)
                        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                        .tracking(0.3)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(color, in: Capsule(style: .continuous))

                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct GuideCatalogRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
