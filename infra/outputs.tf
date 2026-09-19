# ---------------------------------------------------------------------------
# Lo que necesitas saber despues de aplicar
# ---------------------------------------------------------------------------
# Estos valores los consume la API de .NET (que necesita el nombre del bus) y
# tu, para comprobar a mano que el flujo funciona.
# ---------------------------------------------------------------------------

output "bus_de_eventos" {
  description = "Nombre del bus. La API de .NET lo necesita para publicar."
  value       = aws_cloudwatch_event_bus.principal.name
}

output "regla" {
  description = "Nombre de la regla de filtrado."
  value       = aws_cloudwatch_event_rule.resenyas.name
}

output "analisis" {
  description = "Quien analiza las resenyas, y con que modelo."
  value       = var.proveedor_analisis == "lexico" ? "lexico (sin IA)" : "${var.proveedor_analisis}: ${local.modelos[var.proveedor_analisis]}"
}

output "secretos_llm" {
  description = "Los secretos donde guardar cada clave. Se rellenan a mano: ver docs/IA.md."
  value       = { for p, s in aws_secretsmanager_secret.clave_llm : p => s.name }
}

output "comparar" {
  description = "Comando para comparar los motores de analisis sobre pruebas/comparacion.json."
  value       = "python src/lambda/comparar.py"
}

output "cola_url" {
  description = "URL de la cola principal. Se usa para leer mensajes a mano."
  value       = aws_sqs_queue.resenyas.url
}

output "cola_dlq_url" {
  description = "URL de la cola de mensajes muertos. Si aqui hay algo, algo fallo."
  value       = aws_sqs_queue.muertos.url
}

output "topic_alertas" {
  description = "ARN del topic de SNS."
  value       = aws_sns_topic.alertas.arn
}

output "flujo" {
  description = "Estado del interruptor general."
  value       = var.flujo_activo ? "ACTIVO" : "APAGADO (flujo_activo = false)"
}

output "apagado_nocturno" {
  description = "Si hay cita nocturna de apagado, y a que hora."
  value       = var.apagado_nocturno ? "${var.apagado_cron} (${var.apagado_zona_horaria})" : "desactivado"
}

output "topic_operaciones" {
  description = "ARN del topic de las alarmas tecnicas."
  value       = aws_sns_topic.operaciones.arn
}

output "alarmas" {
  description = "Las tres alarmas, de la mas temprana a la ultima red."
  value = [
    aws_cloudwatch_metric_alarm.mensajes_fallidos.alarm_name,
    aws_cloudwatch_metric_alarm.errores_lambda.alarm_name,
    aws_cloudwatch_metric_alarm.dlq_con_mensajes.alarm_name,
    aws_cloudwatch_metric_alarm.analisis_degradado.alarm_name,
  ]
}

output "funcion_analizador" {
  description = "Nombre de la Lambda."
  value       = aws_lambda_function.analizador.function_name
}

output "ver_logs" {
  description = "Comando para ver en directo lo que escribe la Lambda."
  value       = "aws logs tail ${aws_cloudwatch_log_group.analizador.name} --follow --region ${var.region}"
}

# ---------------------------------------------------------------------------
# Un recordatorio que ahorra media hora de desconcierto
# ---------------------------------------------------------------------------
# La suscripcion de SNS por correo NO esta activa hasta que se pulsa el enlace
# del mensaje de confirmacion. Es el fallo mas comun al montar esto: todo
# parece correcto, el mensaje llega a la cola, la Lambda publica en el topic, y
# no aparece ningun correo. El motivo casi siempre es este clic pendiente.
# ---------------------------------------------------------------------------

output "siguiente_paso" {
  description = "Que hacer justo despues del apply."
  # nonsensitive() se aplica a la COMPARACION, no al correo: lo que se desmarca
  # es el booleano "hay correo o no", que no revela la direccion. Sin esto,
  # Terraform contagia la marca de sensible a toda la salida y la oculta.
  value = nonsensitive(var.email_alertas == "") ? "Sin correo configurado: el topic existe pero no tiene suscriptores. Pon email_alertas en terraform.tfvars y vuelve a aplicar." : "Revisa tu bandeja y CONFIRMA la suscripcion de SNS pulsando el enlace. Comprobarlo: aws sns list-subscriptions-by-topic --topic-arn ${aws_sns_topic.alertas.arn} --query Subscriptions[].SubscriptionArn --output text"
}
