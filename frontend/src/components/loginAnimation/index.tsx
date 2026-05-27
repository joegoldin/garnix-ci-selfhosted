import Lottie from "react-lottie";
import { Text } from "@/components/text";
import lottieData from "./animation.json";
import styles from "./styles.module.css";

type Props = {
  text: string;
  onAnimationDone: () => void;
};

export const LoginAnimation = ({ text, onAnimationDone }: Props) => {
  return (
    <div className={styles.container}>
      <Lottie
        style={{ height: 100 }}
        options={{
          loop: false,
          autoplay: true,
          animationData: lottieData,
        }}
        isClickToPauseDisabled
        eventListeners={[
          {
            eventName: "complete",
            callback: () => {
              onAnimationDone();
            },
          },
        ]}
      />
      <Text>{text}</Text>
    </div>
  );
};
