# Adwaita's folder icons are blue whatever the theme: these are its blues as
# the theme's accent, the base, a deeper shade behind and three pale ones in
# front. nova-theme-apply runs this over the icons it copies (apply_gtk).
s/#62a0ea/{{ accent }}/gI
s/#438de6/{{ mix accent #000000 20% }}/gI
s/#a4caee/{{ mix accent #ffffff 28% }}/gI
s/#afd4ff/{{ mix accent #ffffff 38% }}/gI
s/#c0d5ea/{{ mix accent #ffffff 33% }}/gI
