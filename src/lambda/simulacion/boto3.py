# boto3 FALSO, solo para la simulacion: no envia nada, solo avisa de lo que
# enviaria. Existe para poder ejecutar manejador.py en local sin AWS ni
# credenciales. Solo lo carga simular_esm.py; nada mas del proyecto lo ve.


class _SnsFalso:
    def publish(self, TopicArn, Subject, Message):
        print(f"      [SNS] enviaria el correo -> {Subject}")


def client(nombre):
    return _SnsFalso()
