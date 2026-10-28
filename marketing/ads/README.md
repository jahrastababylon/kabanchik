# Рекламные креативы Tropami

4 идеи × 2 формата: `_sq` — 1080×1080 (лента Facebook/Instagram), `_st` — 1080×1920 (Stories, Reels, TikTok; текст вне «опасных зон»).

| Файл | Идея | Основной текст (Primary text) | Заголовок (Headline) | Ссылка |
|---|---|---|---|---|
| A | Dzik pod blokiem? | Widziałeś dzika pod blokiem albo lisa na podwórku? Zaznacz go na mapie Tropami — sąsiedzi zobaczą, co dzieje się na osiedlu, a naukowcy dostaną dane o dzikich zwierzętach w mieście. | Mapa dzikich zwierząt w Twoim mieście | `tropami.com/app/?src=meta-a` |
| B | Kto mieszka na Twoim osiedlu? | Jeże, wiewiórki, lisy, ptaki — zobacz, kogo spotykają sąsiedzi, i dodaj swoje obserwacje. Codziennie zagadka i odznaki za spacery. | Kto mieszka na Twoim osiedlu? | `tropami.com/app/?src=meta-b` |
| C | Zagadka dnia | Zgadniesz? Odpowiedź czeka w Tropami — codziennie nowa zagadka o zwierzętach w mieście. | Zagadka: lis zimą | `tropami.com/app/?src=meta-c` |
| D | Ślady dzika | Rozkopany trawnik, tropy w błocie, nora pod krzakiem — ślady też się liczą. Do dzika nie podchodź: zgłoś z daleka. | Ślady dzika? Zgłoś je w Tropami | `tropami.com/app/?src=meta-d` |

`?src=` попадает в статистику (`app_open.src`) — видно, какой креатив приводит людей (запрос в `supabase/SETUP_v8.md`).

**Как поменять текст или сделать EN-версию:** открыть `ad.html?c=A&f=sq` (или `f=st`) в Chrome, поправить текст в файле, сделать скриншот окна нужного размера
(DevTools → Toggle device toolbar → 1080×1080 или 1080×1920 → «Capture screenshot»).

Карта в макете — © OpenStreetMap (подпись внутри макета оставить). Пины на макете иллюстративные.
