//! Lecture de la config depuis config.csv (colonnes : section,cle,valeur,version,description).
//! On ne garde que section+cle -> valeur ; les valeurs sont converties a la demande.

use std::collections::HashMap;

pub struct Config {
    valeurs: HashMap<String, String>, // clef = "section.cle"
}

impl Config {
    // Charge config.csv. Panique si absent/illisible : le serveur ne peut pas demarrer sans.
    pub fn charger(chemin: &str) -> Config {
        let mut valeurs = HashMap::new();
        let mut lecteur = csv::ReaderBuilder::new()
            .has_headers(true)
            .flexible(true)
            .from_path(chemin)
            .expect("config.csv introuvable ou illisible");

        for ligne in lecteur.records() {
            let rec = ligne.expect("ligne CSV invalide");
            if rec.len() < 3 {
                continue;
            }
            let section = rec.get(0).unwrap().trim();
            let cle = rec.get(1).unwrap().trim();
            let valeur = rec.get(2).unwrap().trim();
            if section.is_empty() || cle.is_empty() {
                continue;
            }
            valeurs.insert(format!("{}.{}", section, cle), valeur.to_string());
        }
        Config { valeurs }
    }

    fn brut(&self, clef: &str) -> String {
        let v = self.valeurs.get(clef);
        if v.is_none() {
            panic!("config : clef manquante '{}'", clef);
        }
        v.unwrap().clone()
    }

    pub fn texte(&self, clef: &str) -> String {
        self.brut(clef)
    }

    pub fn entier(&self, clef: &str) -> i64 {
        self.brut(clef).parse::<i64>().expect("config : entier invalide")
    }

    pub fn booleen(&self, clef: &str) -> bool {
        self.brut(clef) == "true"
    }
}
