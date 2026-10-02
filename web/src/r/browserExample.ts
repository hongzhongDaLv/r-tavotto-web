export const exampleScript = `# Synthetic, reproducible example. No research data.
library(ggplot2)
set.seed(2718)
groups <- factor(rep(c("Control", "Low", "Medium", "High"), each = 12),
                 levels = c("Control", "Low", "Medium", "High"))
d <- data.frame(treatment = groups,
                value = rnorm(48, rep(c(8, 10, 13, 16), each = 12), 2))
s <- aggregate(value ~ treatment, d, function(x) c(mean = mean(x), se = sd(x)/sqrt(length(x))))
s <- data.frame(treatment = s$treatment, mean = s$value[, 1], se = s$value[, 2])
p <- ggplot(s, aes(treatment, mean, fill = treatment)) +
  geom_col(width = 0.6, colour = "#243544", linewidth = 0.5, alpha = 0.9) +
  geom_errorbar(aes(ymin = mean - se, ymax = mean + se), width = 0.15, linewidth = 0.55) +
  geom_point(data = d, aes(treatment, value, colour = treatment, fill = treatment),
             inherit.aes = FALSE, shape = 21, size = 2.8, stroke = 0.45, alpha = 0.8,
             position = position_jitter(width = 0.09, height = 0, seed = 2718)) +
  scale_fill_manual(values = c("#AEC8D9", "#B8D3B0", "#EEC693", "#C6B4D3")) +
  scale_colour_manual(values = c("#4A7896", "#59844B", "#AC7337", "#785891")) +
  scale_y_continuous(limits = c(0, 22), breaks = seq(0, 20, 5), expand = expansion(mult = c(0, 0.02))) +
  labs(title = "Treatment response", subtitle = "Mean, standard error and individual observations",
       x = "Treatment", y = expression("Response (mg kg"^{-1}*")"),
       caption = "Synthetic data · n = 12 per group") +
  theme_classic(base_size = 13) +
  theme(legend.position = "none", plot.title = element_text(face = "bold"),
        plot.margin = margin(18, 24, 18, 18))
ggsave("example.svg", p, width = 900, height = 600, units = "px", dpi = 96)
`
