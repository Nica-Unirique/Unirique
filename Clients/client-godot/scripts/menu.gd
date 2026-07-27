extends Node3D

## Menu de la plateforme. L'UI est construite UNE fois dans un SubViewport, puis
## affichée de deux façons :
##   - à plat : un SubViewportContainer plein écran (la souris marche nativement)
##   - en VR  : un panneau 3D texturé par le viewport, pointé au rayon de la manette
##
## Un seul jeu de Controls, deux surfaces. Purement CLIENT : ne passe pas par le
## contrat.

## SEPT sous-menus. Les six premiers ont leur rectangle dans le menu principal ;
## CONNEXION n'en a pas — on n'y va jamais volontairement, on y est envoyé quand
## une section protégée exige un compte.
const SOUS_MENUS := [
	"AMIS", "COMMUNAUTE", "NOTIFICATIONS", "AVATARS", "COMPTE", "REGLAGES",
	"CONNEXION",
]
## Les rectangles du menu principal : les six premiers sous-menus.
const NB_SECTIONS := 6

const COMPTE_ := 4
const CONNEXION := 6
## Sous-menus qui demandent un compte. AVATARS et REGLAGES restent libres : on
## doit pouvoir régler son affichage sans identité.
const PROTEGES := [0, 1, 2, 4]

## Contenu d'un sous-menu, chargé à sa première ouverture. Absent = vide.
const CONTENU_SCRIPTS := {
	0: "res://scripts/menu_amis.gd",
	4: "res://scripts/menu_compte.gd",
	5: "res://scripts/menu_settings.gd",
	6: "res://scripts/menu_connexion.gd",
}

## Teinte des rectangles ; l'alpha vient de interface.menu_opacity.
const FOND := Color(0.0, 0.0, 0.0, 0.5)
const SECTION_LARGEUR := 0.12
const SECTION_HAUTEUR := 0.55
const SOUS_MENU_LARGEUR := 0.8
const SOUS_MENU_RATIO := 9.0 / 16.0
const ESPACEMENT := 16
const TAILLE_BASE := 16
const TAILLE_TITRE := 28

## En VR le viewport a une résolution fixe ; à plat il suit la fenêtre.
const RES_VR := Vector2i(1280, 720)
## Panneau VR : dimensions en mètres et distance devant le joueur.
const PANNEAU_METRES := Vector2(1.6, 0.9)
const PANNEAU_DISTANCE := 1.6

const VrRig := preload("res://scripts/vr.gd")
const Compte := preload("res://scripts/compte.gd")

## Relayé depuis un sous-menu vers le client. Le menu ne sait pas s'y connecter
## lui-même : rejoindre un serveur n'est pas son affaire.
signal rejoindre_serveur(adresses: Array)

## Injectés par client.gd AVANT add_child (donc lisibles dès _ready).
var vr: VrRig
var compte: Compte

var ouvert := false
## Sous-menu affiché, -1 quand on est sur le menu principal.
var actif := -1
## Sous-menu protégé demandé sans compte : on y atterrit une fois connecté.
var attendu := -1

var viewport: SubViewport
var racine: Control
var principal: CenterContainer
var sous_menu: CenterContainer
var cadre: PanelContainer
var titre: Label
var contenu: MarginContainer
var boutons: Array[Button] = []
var contenus := {}
var style_fond: StyleBoxFlat
var theme_menu: Theme

## Surfaces d'affichage : l'une ou l'autre selon le mode.
var ecran: CanvasLayer     # à plat
var quad: MeshInstance3D    # VR
var hud: CanvasLayer        # compteur FPS, toujours à l'écran (plat)
var compteur_fps: Label

## Pointeur VR, une par main. Rayon 3D + point dans le viewport, affichés
## SEULEMENT quand le rayon de CETTE main touche le panneau.
const MAINS := ["left", "right"]
var rayons := {}    # main -> MeshInstance3D
var curseurs := {}  # main -> Panel
## Le viewport n'a qu'une souris : une seule main tient le clic à la fois.
## "" = aucune. L'autre main continue de pointer.
var proprietaire := ""
var pixel_proprietaire := Vector2.ZERO


func _ready() -> void:
	style_fond = StyleBoxFlat.new()
	theme_menu = Theme.new()

	_construire_ui()
	if _en_vr():
		_construire_panneau_vr()
	else:
		_construire_ecran_plat()
	_construire_hud()

	viewport.size_changed.connect(_ajuster_tailles)
	_ajuster_tailles()
	compte.change.connect(_sur_compte_change)
	Settings.applied.connect(_appliquer_reglages)
	_appliquer_reglages()
	_fermer()


func _en_vr() -> bool:
	return vr != null and vr.actif


## --- Construction de l'UI (dans le viewport) ---

func _construire_ui() -> void:
	viewport = SubViewport.new()
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if _en_vr():
		viewport.size = RES_VR
		add_child(viewport)  # rendu hors écran, lu par le quad

	racine = Control.new()
	racine.set_anchors_preset(Control.PRESET_FULL_RECT)
	racine.mouse_filter = Control.MOUSE_FILTER_IGNORE
	racine.theme = theme_menu
	viewport.add_child(racine)

	_construire_principal()
	_construire_sous_menu()


## Les 6 rectangles verticaux, centrés.
func _construire_principal() -> void:
	principal = CenterContainer.new()
	principal.set_anchors_preset(Control.PRESET_FULL_RECT)
	principal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	racine.add_child(principal)

	var ligne := HBoxContainer.new()
	ligne.add_theme_constant_override("separation", ESPACEMENT)
	principal.add_child(ligne)

	for i in NB_SECTIONS:
		var bouton := _creer_bouton(SOUS_MENUS[i])
		bouton.pressed.connect(_ouvrir_section.bind(i))
		ligne.add_child(bouton)
		boutons.append(bouton)


## Le cadre 16:9 unique, partagé par les 6 sections.
func _construire_sous_menu() -> void:
	sous_menu = CenterContainer.new()
	sous_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	sous_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sous_menu.visible = false
	racine.add_child(sous_menu)

	cadre = PanelContainer.new()
	cadre.add_theme_stylebox_override("panel", style_fond)
	sous_menu.add_child(cadre)

	var colonne := VBoxContainer.new()
	colonne.add_theme_constant_override("separation", ESPACEMENT)
	cadre.add_child(colonne)

	titre = Label.new()
	titre.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	titre.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	colonne.add_child(titre)

	contenu = MarginContainer.new()
	contenu.size_flags_vertical = Control.SIZE_EXPAND_FILL
	colonne.add_child(contenu)


func _creer_bouton(texte: String) -> Button:
	var bouton := Button.new()
	bouton.text = texte
	bouton.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	bouton.clip_text = false
	# Même fond dans tous les états : pas de highlight.
	for etat in ["normal", "hover", "pressed", "focus", "disabled"]:
		bouton.add_theme_stylebox_override(etat, style_fond)
	return bouton


## --- Surfaces d'affichage ---

## À plat : le container gère la souris et étire le viewport à la fenêtre.
func _construire_ecran_plat() -> void:
	ecran = CanvasLayer.new()
	var container := SubViewportContainer.new()
	container.stretch = true
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.add_child(viewport)
	ecran.add_child(container)
	add_child(ecran)


## En VR : un panneau texturé par le viewport, placé devant le joueur à l'ouverture.
func _construire_panneau_vr() -> void:
	var maillage := QuadMesh.new()
	maillage.size = PANNEAU_METRES

	var matiere := StandardMaterial3D.new()
	matiere.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	matiere.albedo_texture = viewport.get_texture()
	matiere.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Texture prise telle quelle : l'orientation vient de la géométrie du panneau,
	# pas de retournements d'UV (qui n'ont fait qu'introduire un miroir).

	quad = MeshInstance3D.new()
	quad.mesh = maillage
	quad.material_override = matiere
	quad.visible = false
	add_child(quad)

	for main in MAINS:
		rayons[main] = _creer_rayon()
		curseurs[main] = _creer_curseur()


## Fin tube coloré de la manette au point d'impact. Orienté chaque frame.
func _creer_rayon() -> MeshInstance3D:
	var tube := CylinderMesh.new()
	tube.top_radius = 0.004
	tube.bottom_radius = 0.004
	tube.height = 1.0
	tube.radial_segments = 6

	var matiere := StandardMaterial3D.new()
	matiere.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	matiere.albedo_color = Color(0.4, 0.8, 1.0, 0.8)
	matiere.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var noeud := MeshInstance3D.new()
	noeud.mesh = tube
	noeud.material_override = matiere
	noeud.visible = false
	add_child(noeud)
	return noeud


## Point dessiné DANS le viewport, à la position pixel : il tombe donc exactement
## là où le clic s'enregistre, comme la souris à plat.
func _creer_curseur() -> Panel:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.9)
	style.set_corner_radius_all(8)

	var noeud := Panel.new()
	noeud.add_theme_stylebox_override("panel", style)
	noeud.size = Vector2(16, 16)
	noeud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	noeud.visible = false
	racine.add_child(noeud)  # au-dessus du reste, dans le viewport
	return noeud


func _construire_hud() -> void:
	hud = CanvasLayer.new()
	compteur_fps = Label.new()
	compteur_fps.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	compteur_fps.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	compteur_fps.offset_top = 8
	compteur_fps.offset_right = -12
	compteur_fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hud.add_child(compteur_fps)
	add_child(hud)


## --- Réglages ---

func _appliquer_reglages() -> void:
	var opacite: int = Settings.get_value("interface.menu_opacity")
	style_fond.bg_color = Color(FOND.r, FOND.g, FOND.b, opacite / 100.0)

	# Le compteur d'images est un repère à plat ; en VR il collerait au visage.
	var afficher: bool = Settings.get_value("interface.show_fps") and not _en_vr()
	compteur_fps.visible = afficher
	set_process(afficher or _en_vr())  # en VR le _process sert au pointeur

	var echelle: float = Settings.get_value("interface.text_size") / 100.0
	theme_menu.default_font_size = int(TAILLE_BASE * echelle)
	titre.add_theme_font_size_override("font_size", int(TAILLE_TITRE * echelle))


func _ajuster_tailles() -> void:
	var taille := Vector2(viewport.size)
	for bouton in boutons:
		bouton.custom_minimum_size = Vector2(
			taille.x * SECTION_LARGEUR, taille.y * SECTION_HAUTEUR
		)
	var largeur := taille.x * SOUS_MENU_LARGEUR
	cadre.custom_minimum_size = Vector2(largeur, largeur * SOUS_MENU_RATIO)


func _process(_delta: float) -> void:
	if compteur_fps.visible:
		compteur_fps.text = "%d FPS" % Engine.get_frames_per_second()
	if _en_vr() and ouvert:
		_pointer_vr()


## --- Ouverture / navigation (piloté par client.gd via l'action `menu`) ---

## Un appui = une étape en arrière : fermé -> ouvert ; sous-menu -> menu
## principal ; menu principal -> fermé.
func basculer() -> void:
	if not ouvert:
		_ouvrir()
	elif actif >= 0:
		# Un sous-menu à plusieurs écrans consomme le retour pour reculer chez
		# lui — sinon on quitterait un assistant en cours d'un seul appui.
		if contenus.has(actif) and contenus[actif].has_method("retour"):
			if contenus[actif].retour():
				return
		_retour()
	else:
		_fermer()


func _ouvrir() -> void:
	ouvert = true
	_afficher(true)
	if _en_vr():
		_placer_panneau()
	_retour()


func _fermer() -> void:
	ouvert = false
	actif = -1
	_afficher(false)


func _afficher(visible: bool) -> void:
	if _en_vr():
		quad.visible = visible
		if not visible:
			# Menu fermé : relâcher un clic éventuel, cacher les deux pointeurs.
			if proprietaire != "":
				_pousser_bouton(pixel_proprietaire, false)
				proprietaire = ""
			for main in MAINS:
				rayons[main].visible = false
				curseurs[main].visible = false
	else:
		ecran.visible = visible


## Sous-menu -> menu principal.
func _retour() -> void:
	actif = -1
	sous_menu.visible = false
	principal.visible = true


## Clic sur un rectangle du menu principal. Un sous-menu protégé sans compte
## n'est pas ouvert : on est envoyé vers CONNEXION, et il est mémorisé pour y
## atterrir une fois connecté.
func _ouvrir_section(i: int) -> void:
	if PROTEGES.has(i) and not compte.connecte:
		attendu = i
		_ouvrir_sous_menu(CONNEXION)
		return
	_ouvrir_sous_menu(i)


## Le seul chemin d'ouverture d'un sous-menu, quel qu'il soit. `actif` dit donc
## toujours la vérité sur ce qui est affiché.
func _ouvrir_sous_menu(index: int) -> void:
	actif = index
	titre.text = SOUS_MENUS[index]
	_montrer_contenu(index)
	principal.visible = false
	sous_menu.visible = true


## La garde est un INVARIANT, pas une vérification au clic : se déconnecter en
## étant dans un sous-menu protégé doit en sortir, sinon on y resterait bloqué.
func _sur_compte_change() -> void:
	if not compte.connecte:
		if ouvert and PROTEGES.has(actif):
			attendu = actif
			_ouvrir_sous_menu(CONNEXION)
		return

	# Connecté : on ouvre enfin le sous-menu qui avait été refusé — mais
	# seulement si l'on est encore devant l'écran de connexion. Être parti
	# ailleurs entre-temps et se le voir arracher serait pire.
	if attendu < 0 or not ouvert or actif != CONNEXION:
		return
	var voulu := attendu
	attendu = -1
	_ouvrir_sous_menu(voulu)


func _montrer_contenu(i: int) -> void:
	for noeud in contenus.values():
		noeud.visible = false
	if not CONTENU_SCRIPTS.has(i):
		return
	if not contenus.has(i):
		contenus[i] = _charger_contenu(i)
	contenus[i].visible = true
	# Chaque ouverture repart de l'accueil du sous-menu, plutôt que de rouvrir
	# sur l'écran laissé la fois précédente.
	if contenus[i].has_method("reinitialiser"):
		contenus[i].reinitialiser()


## Aucun cas particulier par sous-menu : on ne branche que ce qu'il déclare.
## Un sous-menu est autonome — le menu ne sait ni ce qu'il contient, ni comment
## il fonctionne. Seule son OUVERTURE lui vient de l'extérieur.
func _charger_contenu(i: int) -> Control:
	var noeud: Control = load(CONTENU_SCRIPTS[i]).new()
	noeud.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	noeud.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Posé AVANT add_child : le sous-menu le lit dans son _ready.
	if "compte" in noeud:
		noeud.compte = compte

	contenu.add_child(noeud)

	# Un sous-menu peut demander l'ouverture d'un autre. C'est de la navigation,
	# pas une délégation : il ne sait rien de celui qu'il ouvre.
	if noeud.has_signal("ouvrir_sous_menu"):
		noeud.ouvrir_sous_menu.connect(_ouvrir_sous_menu)

	# Relais : le sous-menu ne connaît pas le client, le menu non plus.
	if noeud.has_signal("rejoindre_serveur"):
		noeud.rejoindre_serveur.connect(_relayer_rejoindre)
	return noeud


## Fermer le menu en passant : on va dans le monde, pas dans une liste.
func _relayer_rejoindre(adresses: Array) -> void:
	_fermer()
	rejoindre_serveur.emit(adresses)


## --- Panneau VR : placement et pointeur ---

## Placé devant le joueur, à hauteur des yeux, face à lui. Fixe une fois ouvert :
## on peut tourner la tête autour.
func _placer_panneau() -> void:
	var camera: Node3D = vr.camera
	var devant := -camera.global_transform.basis.z
	devant.y = 0.0
	devant = devant.normalized()

	var position := camera.global_position + devant * PANNEAU_DISTANCE
	position.y = camera.global_position.y

	# Base orientée +Z vers le joueur, sans miroir : X = UP x Z, Y = Z x X.
	var vers_z := (camera.global_position - position).normalized()
	var vers_x := Vector3.UP.cross(vers_z).normalized()
	var vers_y := vers_z.cross(vers_x)
	quad.global_transform = Transform3D(Basis(vers_x, vers_y, vers_z), position)


## Chaque main pointe indépendamment ; le clic est arbitré entre les deux.
func _pointer_vr() -> void:
	var etats := {}
	for main in MAINS:
		etats[main] = _maj_main(main)
	_maj_clic_mains(etats)


## Met à jour rayon + curseur d'UNE main. Renvoie {touche, pixel}.
func _maj_main(main: String) -> Dictionary:
	var pointeur := vr.transform_pointeur(main)
	var origine := pointeur.origin
	var direction := -pointeur.basis.z

	var touche := false
	var pixel := Vector2.ZERO
	var impact = _impact_panneau(origine, direction)
	if impact != null:
		# impact est Variant (null ou Vector3) : on type explicitement la suite.
		var local: Vector3 = quad.global_transform.affine_inverse() * impact
		# Convention UV de QuadMesh, sans retournement : cohérent avec l'affichage.
		var u: float = local.x / PANNEAU_METRES.x + 0.5
		var v: float = 0.5 - local.y / PANNEAU_METRES.y
		if u >= 0.0 and u <= 1.0 and v >= 0.0 and v <= 1.0:
			touche = true
			pixel = Vector2(u * RES_VR.x, v * RES_VR.y)
			curseurs[main].position = pixel - curseurs[main].size * 0.5
			_orienter_rayon(rayons[main], origine, impact)

	curseurs[main].visible = touche
	rayons[main].visible = touche
	return {"touche": touche, "pixel": pixel}


## Point d'intersection rayon/plan du panneau, ou null si le rayon s'en éloigne.
func _impact_panneau(origine: Vector3, direction: Vector3):
	var normale := quad.global_transform.basis.z
	var denominateur := direction.dot(normale)
	if absf(denominateur) < 0.0001:
		return null
	var distance := (quad.global_position - origine).dot(normale) / denominateur
	if distance <= 0.0:
		return null
	return origine + direction * distance


func _pousser_souris(pixel: Vector2) -> void:
	var evenement := InputEventMouseMotion.new()
	evenement.position = pixel
	viewport.push_input(evenement, true)


func _pousser_bouton(pixel: Vector2, presse: bool) -> void:
	var evenement := InputEventMouseButton.new()
	evenement.button_index = MOUSE_BUTTON_LEFT
	evenement.pressed = presse
	evenement.position = pixel
	viewport.push_input(evenement, true)


## Une seule main tient le clic. Tant qu'elle le tient, sa position pilote la
## souris (le survol reste sur son bouton). Sinon, la première main qui appuie
## sur le panneau prend le clic.
func _maj_clic_mains(etats: Dictionary) -> void:
	if proprietaire != "":
		var etat: Dictionary = etats[proprietaire]
		if etat["touche"] and vr.bouton(proprietaire, "trigger_click"):
			pixel_proprietaire = etat["pixel"]
			_pousser_souris(pixel_proprietaire)
		else:
			_pousser_souris(pixel_proprietaire)
			_pousser_bouton(pixel_proprietaire, false)
			proprietaire = ""
		return

	for main in MAINS:
		var etat: Dictionary = etats[main]
		if etat["touche"] and vr.bouton(main, "trigger_click"):
			_pousser_souris(etat["pixel"])
			_pousser_bouton(etat["pixel"], true)
			proprietaire = main
			pixel_proprietaire = etat["pixel"]
			vr.vibrer(main, 0.4, 0.04)
			return


## Tend le tube du contrôleur au point d'impact : Y du cylindre aligné sur la
## direction, mis à l'échelle de la longueur.
func _orienter_rayon(noeud: MeshInstance3D, origine: Vector3, impact: Vector3) -> void:
	var ecart := impact - origine
	var longueur := ecart.length()
	if longueur < 0.001:
		return
	var axe_y := ecart / longueur
	var axe_x := Vector3.UP.cross(axe_y)
	if axe_x.length() < 0.001:
		axe_x = Vector3.RIGHT
	axe_x = axe_x.normalized()
	var axe_z := axe_x.cross(axe_y).normalized()
	noeud.global_transform = Transform3D(
		Basis(axe_x, axe_y * longueur, axe_z), (origine + impact) * 0.5
	)
